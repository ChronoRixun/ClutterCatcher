import Foundation
import GRDB

// The two write paths (plan §3.2). They are deliberately separate context
// types with separate entry points — not a flag — so a server apply can never
// restamp or echo, and a local mutation can never skip its bookkeeping:
//
// - `AppDatabase.performLocalMutation` → `LocalMutation`: user-driven
//   changes. Stamps `updated_at` and enqueues outbound `pending_changes`
//   rows in the same transaction as the change itself.
// - `AppDatabase.applyServerChanges` → `ServerApply`: inbound sync. Applies
//   server rows verbatim and never writes to the outbound queue.

extension AppDatabase {
    /// THE write path for user-driven changes to synced tables.
    func performLocalMutation<T: Sendable>(
        _ updates: @escaping @Sendable (LocalMutation) throws -> T
    ) async throws -> T {
        try await writer.write { db in
            try updates(LocalMutation(db: db, now: Date()))
        }
    }

    /// Synchronous twin of `performLocalMutation`, for the pre-UI bootstrap
    /// path (seeding). Same context, same guarantees.
    func performLocalMutationSync<T>(
        _ updates: (LocalMutation) throws -> T
    ) throws -> T {
        try writer.write { db in
            try updates(LocalMutation(db: db, now: Date()))
        }
    }

    /// THE write path for changes fetched from the server.
    func applyServerChanges<T: Sendable>(
        _ updates: @escaping @Sendable (ServerApply) throws -> T
    ) async throws -> T {
        try await writer.write { db in
            try updates(ServerApply(db: db))
        }
    }
}

// MARK: - Local mutations

/// Write context for user-driven changes. Only `performLocalMutation`
/// creates one.
struct LocalMutation {
    /// The raw connection, for reads and local-only-table writes that belong
    /// in the same transaction.
    let db: Database
    /// One clock reading per mutation: every row saved in this transaction
    /// carries the same `updated_at`, every queue entry the same `queued_at`.
    let now: Date

    /// Inserts or updates a synced row, stamping `updated_at` and enqueueing
    /// the outbound save. Callers never stamp timestamps themselves.
    func save<R: SyncedRecord>(_ record: inout R) throws {
        record.updatedAt = now
        try record.save(db)
        try enqueue(.save, R.syncRecordType, record.id)
    }

    // MARK: Deletes
    //
    // Local FK cascades are mirrored as explicit outbound deletes, children
    // first (items → containers → rooms), so the server and every other
    // device converge on the same end state (plan §3.1/§3.2).

    func deleteRooms(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let containerIDs = try String.fetchAll(
            db,
            sql: "SELECT id FROM containers WHERE room_id IN (\(placeholders(ids)))",
            arguments: StatementArguments(ids))
        try deleteContainers(ids: containerIDs)
        try enqueueDeletes(.room, ids)
        try Room.deleteAll(db, keys: ids)
    }

    func deleteContainers(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let itemIDs = try String.fetchAll(
            db,
            sql: "SELECT id FROM items WHERE container_id IN (\(placeholders(ids)))",
            arguments: StatementArguments(ids))
        try deleteItems(ids: itemIDs)
        try enqueueDeletes(.container, ids)
        try Container.deleteAll(db, keys: ids)
    }

    func deleteItems(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try enqueueDeletes(.item, ids)
        try Item.deleteAll(db, keys: ids)
    }

    /// Clears the reference on affected items as tracked saves *before* the
    /// delete. Relying on the local `SET NULL` cascade alone would leave the
    /// server's copies of those items pointing at a dead category, which
    /// would break a fresh device's bootstrap (FK failure on insert).
    func deleteCategories(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let affected = try Item.fetchAll(
            db,
            sql: "SELECT * FROM items WHERE category_id IN (\(placeholders(ids)))",
            arguments: StatementArguments(ids))
        for var item in affected {
            item.categoryId = nil
            try save(&item)
        }
        try enqueueDeletes(.category, ids)
        try Category.deleteAll(db, keys: ids)
    }

    // MARK: Queue

    private func enqueue(_ kind: PendingChange.Kind, _ type: SyncRecordType, _ id: String) throws {
        try PendingChange(recordId: id, recordType: type, changeKind: kind, queuedAt: now)
            .insert(db, onConflict: .replace)
    }

    private func enqueueDeletes(_ type: SyncRecordType, _ ids: [String]) throws {
        for id in ids {
            try enqueue(.delete, type, id)
        }
    }

    private func placeholders(_ values: [String]) -> String {
        Array(repeating: "?", count: values.count).joined(separator: ",")
    }
}

// MARK: - Server applies

/// Write context for changes that arrived from the server. Only
/// `applyServerChanges` creates one. No stamping, no enqueueing — an inbound
/// change is applied verbatim and never echoed back out.
struct ServerApply {
    let db: Database

    enum ApplyOutcome: Equatable, Sendable {
        /// Server row applied; bookkeeping updated.
        case applied
        /// Local row was newer — kept. Only the server's change tag was
        /// adopted, so the queued local save overwrites cleanly.
        case keptLocal
        /// A parent row is missing (FK): the caller should buffer the record
        /// and retry once the rest of the fetch has landed.
        case orphaned
    }

    /// Applies one server row verbatim, no questions asked. Use
    /// `applyWithMerge` for anything that can conflict with local edits.
    func upsert(_ row: SyncedRow) throws {
        switch row {
        case .room(let room): try room.save(db)
        case .category(let category): try category.save(db)
        case .container(let container): try container.save(db)
        case .item(let item): try item.save(db)
        }
    }

    /// Applies one parsed server record under the LWW policy (D10).
    @discardableResult
    func applyWithMerge(_ parsed: ParsedServerRecord) throws -> ApplyOutcome {
        let id = parsed.row.id
        let pending = try PendingChange.fetchOne(db, key: id)
        let local = try SyncedRow.fetch(db, type: parsed.row.recordType, id: id)
        let resolution = LWWMerge.resolve(
            localUpdatedAt: local?.updatedAt,
            pending: pending.map { ($0.changeKind, $0.queuedAt) },
            serverUpdatedAt: parsed.row.updatedAt)
        switch resolution {
        case .keepLocal:
            try saveMetadata(parsed)
            return .keptLocal
        case .acceptServer:
            do {
                try upsert(parsed.row)
            } catch let error as DatabaseError
                where error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
                return .orphaned
            }
            try saveMetadata(parsed)
            if pending != nil {
                _ = try PendingChange.deleteOne(db, key: id)
            }
            return .applied
        }
    }

    /// Applies a server-side deletion: removes the row (the local FK cascade
    /// takes its children) plus all bookkeeping for it *and* the cascaded
    /// children. Returns the pending changes that were dropped so the caller
    /// can remove them from the engine's in-memory state too.
    @discardableResult
    func applyDeletion(type: SyncRecordType, id: String) throws -> [PendingChange] {
        var ids = [id]
        switch type {
        case .room:
            let containerIDs = try String.fetchAll(
                db, sql: "SELECT id FROM containers WHERE room_id = ?", arguments: [id])
            ids += containerIDs
            ids += try itemIDs(inContainers: containerIDs)
        case .container:
            ids += try itemIDs(inContainers: [id])
        case .category, .item:
            break
        }

        switch type {
        case .room: _ = try Room.deleteOne(db, key: id)
        case .category: _ = try Category.deleteOne(db, key: id)
        case .container: _ = try Container.deleteOne(db, key: id)
        case .item: _ = try Item.deleteOne(db, key: id)
        }

        let dropped = try PendingChange.fetchAll(db, keys: ids)
        try PendingChange.deleteAll(db, keys: ids)
        try RecordMetadata.deleteAll(db, keys: ids)
        return dropped
    }

    func saveMetadata(_ parsed: ParsedServerRecord) throws {
        try RecordMetadata(
            recordId: parsed.row.id,
            recordType: parsed.row.recordType,
            systemFields: parsed.systemFields
        ).insert(db, onConflict: .replace)
    }

    private func itemIDs(inContainers containerIDs: [String]) throws -> [String] {
        guard !containerIDs.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: containerIDs.count).joined(separator: ",")
        return try String.fetchAll(
            db,
            sql: "SELECT id FROM items WHERE container_id IN (\(marks))",
            arguments: StatementArguments(containerIDs))
    }
}
