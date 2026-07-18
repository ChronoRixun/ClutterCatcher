import CloudKit
import Foundation
import GRDB

/// Owns the private-database CKSyncEngine (plan §3.2, M2 scope: one Apple
/// ID, no sharing — the shared-database engine and participant logic are M3).
///
/// Responsibilities:
/// - engine lifecycle: state serialization round-trip through `sync_state`,
///   `Household` zone creation, account monitoring;
/// - outbound: drains `pending_changes` in `nextRecordZoneChangeBatch`,
///   persists returned system fields and clears queue rows on ack, routes
///   `serverRecordChanged` through the LWW merge;
/// - inbound: applies fetched changes through `applyServerChanges` (never
///   the local-mutation path), buffering FK orphans until their parents land;
/// - recovery: zone deleted / purged / `zoneNotFound` → recreate + re-upload.
///
/// The app must stay fully functional with sync off: nothing here blocks the
/// UI, and every failure degrades to "changes stay queued locally".
actor SyncCoordinator {
    private let database: AppDatabase
    private let status: SyncStatusModel
    private let container: CKContainer

    private var engine: CKSyncEngine?
    private var started = false
    private var isRecoveringZone = false
    /// Fetched records whose parent row hasn't arrived yet (CloudKit batches
    /// don't respect our FK order); retried after each batch and drained for
    /// good when the fetch completes.
    private var orphanBuffer: [ParsedServerRecord] = []
    private var pendingObservationTask: Task<Void, Never>?
    private var accountMonitorTask: Task<Void, Never>?

    init(database: AppDatabase, status: SyncStatusModel) {
        self.database = database
        self.status = status
        self.container = CKContainer(identifier: "iCloud.com.rixun.cluttercatcher")
    }

    deinit {
        pendingObservationTask?.cancel()
        accountMonitorTask?.cancel()
    }

    // MARK: Lifecycle

    /// Called once from app bootstrap, after seeding. Safe with no iCloud
    /// account: sync stays off and the app runs local-only.
    func start() async {
        guard !started else { return }
        started = true
        accountMonitorTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                await self?.accountStatusChanged()
            }
        }
        await accountStatusChanged()
    }

    /// Foreground hook: CloudKit pushes don't reliably reach simulators, and
    /// a fetch on activation makes the M2 two-device gate observable.
    func applicationDidBecomeActive() {
        fetchSoon()
    }

    private func accountStatusChanged() async {
        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                await verifyAccountIdentity()
                await startEngineIfNeeded()
            case .noAccount:
                stopEngine(reason: "no iCloud account")
            case .restricted:
                stopEngine(reason: "iCloud restricted")
            case .temporarilyUnavailable:
                stopEngine(reason: "iCloud temporarily unavailable")
            case .couldNotDetermine:
                stopEngine(reason: "iCloud unavailable")
            @unknown default:
                stopEngine(reason: "iCloud unavailable")
            }
        } catch {
            Log.sync.error("Account status check failed: \(String(describing: error))")
            stopEngine(reason: "iCloud unavailable")
        }
    }

    /// The sync bookkeeping (engine state, record metadata) is only valid for
    /// the Apple ID that produced it. If the signed-in user changed while the
    /// app was dead, reset it — the catalog itself stays, and backfill
    /// re-queues everything for the new account's zone.
    private func verifyAccountIdentity() async {
        guard let userRecordID = try? await container.userRecordID() else {
            Log.sync.info("userRecordID unavailable; skipping account-identity check")
            return
        }
        let name = userRecordID.recordName
        do {
            let stored: String? = try await database.writer.read { db in
                try SyncState.fetchOne(db, key: SyncState.accountUserKey)
                    .flatMap { String(data: $0.data, encoding: .utf8) }
            }
            if let stored, stored != name {
                Log.sync.warning("iCloud account changed; resetting sync bookkeeping")
                engine = nil
                try await resetSyncBookkeeping()
            }
            try await database.writer.write { db in
                try SyncState(key: SyncState.accountUserKey, data: Data(name.utf8))
                    .insert(db, onConflict: .replace)
            }
        } catch {
            Log.sync.error("Account identity bookkeeping failed: \(String(describing: error))")
        }
    }

    private func resetSyncBookkeeping() async throws {
        try await database.writer.write { db in
            _ = try SyncState.deleteOne(db, key: SyncState.privateEngineKey)
            try RecordMetadata.deleteAll(db)
            // pending_changes survives: unsent local edits are still edits.
        }
    }

    private func startEngineIfNeeded() async {
        guard engine == nil else {
            await settleStatus()
            return
        }
        let serialization = await loadEngineState()
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self)
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        Log.sync.info("Private-DB sync engine started (\(serialization == nil ? "fresh state" : "resumed state"))")

        if serialization == nil {
            // First run for this account/state: make sure the zone exists.
            // Saving an existing zone is harmless.
            engine.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneName: RecordMapper.zoneName)),
            ])
        }
        do {
            let backfilled = try await database.writer.write { db in
                try SyncBackfill.enqueueUnsyncedRows(db)
            }
            if backfilled > 0 {
                Log.sync.info("Backfill queued \(backfilled) unsynced row(s)")
            }
        } catch {
            Log.sync.error("Backfill failed: \(String(describing: error))")
        }
        startPendingObservation()
        await settleStatus()
        fetchSoon()
    }

    private func stopEngine(reason: String) {
        if engine != nil {
            Log.sync.info("Sync engine stopped: \(reason)")
        }
        engine = nil
        pendingObservationTask?.cancel()
        pendingObservationTask = nil
        setStatus(.off(reason: reason))
    }

    private func fetchSoon() {
        guard let engine else { return }
        Task {
            do {
                try await engine.fetchChanges()
            } catch {
                // Offline is normal here; the engine retries on its own.
                Log.sync.info("Fetch not completed: \(String(describing: error))")
            }
        }
    }

    // MARK: Engine state persistence

    private func loadEngineState() async -> CKSyncEngine.State.Serialization? {
        do {
            guard let stored = try await database.writer.read({ db in
                try SyncState.fetchOne(db, key: SyncState.privateEngineKey)?.data
            }) else { return nil }
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: stored)
        } catch {
            Log.sync.error("Engine state unreadable, starting fresh: \(String(describing: error))")
            return nil
        }
    }

    private func persistEngineState(_ serialization: CKSyncEngine.State.Serialization) async {
        do {
            let data = try JSONEncoder().encode(serialization)
            try await database.writer.write { db in
                try SyncState(key: SyncState.privateEngineKey, data: data)
                    .insert(db, onConflict: .replace)
            }
        } catch {
            Log.sync.error("Persisting engine state failed: \(String(describing: error))")
        }
    }

    // MARK: Outbound queue → engine state

    /// `pending_changes` is the durable queue; the engine's in-memory state
    /// is rebuilt from it via this observation — every local mutation lands
    /// here without repositories knowing sync exists.
    private func startPendingObservation() {
        pendingObservationTask?.cancel()
        pendingObservationTask = Task { [weak self, database] in
            do {
                let observation = database.observe { db in
                    try PendingChange.fetchAll(db)
                }
                for try await pending in observation {
                    await self?.reconcileEnginePending(pending)
                }
            } catch {
                Log.sync.error("Pending-change observation ended: \(String(describing: error))")
            }
        }
    }

    private func reconcileEnginePending(_ pending: [PendingChange]) async {
        guard let engine, !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending.map(\.enginePendingChange))
    }

    // MARK: Status

    private func setStatus(_ phase: SyncStatusModel.Phase) {
        let status = status
        Task { @MainActor in
            status.phase = phase
        }
    }

    private func settleStatus() async {
        guard engine != nil else { return }
        let pendingCount = (try? await database.writer.read { db in
            try PendingChange.fetchCount(db)
        }) ?? 0
        setStatus(pendingCount == 0 ? .upToDate : .syncing)
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncCoordinator: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            await persistEngineState(stateUpdate.stateSerialization)
        case .accountChange(let accountChange):
            await handleAccountChange(accountChange)
        case .fetchedDatabaseChanges(let changes):
            await handleFetchedDatabaseChanges(changes)
        case .fetchedRecordZoneChanges(let changes):
            await handleFetchedRecordZoneChanges(changes)
        case .sentRecordZoneChanges(let sent):
            await handleSentRecordZoneChanges(sent)
        case .sentDatabaseChanges(let sent):
            handleSentDatabaseChanges(sent)
        case .willFetchChanges, .willSendChanges:
            setStatus(.syncing)
        case .didFetchChanges:
            await drainOrphans(fetchComplete: true)
            await settleStatus()
        case .didSendChanges:
            await settleStatus()
        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break
        @unknown default:
            Log.sync.info("Unhandled sync engine event: \(String(describing: event))")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        let database = database
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            let id = recordID.recordName
            let snapshot: (row: SyncedRow, systemFields: Data?)?
            do {
                snapshot = try await database.writer.read { db in
                    guard let row = try SyncedRow.fetch(db, id: id) else { return nil }
                    let metadata = try RecordMetadata.fetchOne(db, key: id)
                    return (row, metadata?.systemFields)
                }
            } catch {
                Log.sync.error("Loading \(id) for send failed: \(String(describing: error))")
                return nil // stays pending; retried on the next send
            }
            guard let snapshot else {
                // Row vanished after being queued (e.g. swept by an inbound
                // cascade) — drop the stale save.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                try? await database.writer.write { db in
                    try db.execute(
                        sql: "DELETE FROM pending_changes WHERE record_id = ? AND change_kind = 'save'",
                        arguments: [id])
                }
                return nil
            }
            return RecordMapper.record(for: snapshot.row, systemFields: snapshot.systemFields)
        }
    }
}

// MARK: - Event handling

private extension SyncCoordinator {
    func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        switch event.changeType {
        case .signIn:
            Log.sync.info("iCloud account signed in")
            await accountStatusChanged()
        case .signOut:
            Log.sync.info("iCloud account signed out; data stays local")
            stopEngine(reason: "no iCloud account")
        case .switchAccounts:
            Log.sync.warning("iCloud account switched; resetting sync bookkeeping")
            engine = nil
            pendingObservationTask?.cancel()
            pendingObservationTask = nil
            do {
                try await resetSyncBookkeeping()
            } catch {
                Log.sync.error("Bookkeeping reset failed: \(String(describing: error))")
            }
            await accountStatusChanged()
        @unknown default:
            Log.sync.info("Unhandled account change")
        }
    }

    func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) async {
        for deletion in event.deletions where deletion.zoneID.zoneName == RecordMapper.zoneName {
            Log.sync.warning(
                "Household zone deleted on server (\(String(describing: deletion.reason)))")
            await recoverFromMissingZone(context: "database change")
        }
    }

    func handleFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        var parsed: [ParsedServerRecord] = []
        var unparseable: [(type: String, id: String)] = []
        for modification in event.modifications {
            let record = modification.record
            do {
                parsed.append(try RecordMapper.parse(record))
            } catch {
                Log.sync.error("Dropping unparseable server record \(record.recordID.recordName): \(String(describing: error))")
                unparseable.append((record.recordType, record.recordID.recordName))
            }
        }
        if !unparseable.isEmpty {
            let receipts = unparseable
            try? await database.writer.write { db in
                for entry in receipts {
                    try SyncEvent.append(
                        db, kind: .serverRecordDropped,
                        recordType: SyncRecordType(rawValue: entry.type), recordId: entry.id,
                        summary: "A record from iCloud (\(entry.type)) couldn't be read and was skipped.")
                }
            }
        }
        var deletions: [(type: SyncRecordType, id: String)] = []
        for deletion in event.deletions {
            guard let type = SyncRecordType(rawValue: deletion.recordType) else {
                Log.sync.info("Ignoring deletion of unknown record type \(deletion.recordType)")
                continue
            }
            deletions.append((type, deletion.recordID.recordName))
        }
        await applyServerBatch(saves: parsed, deletions: deletions)
    }

    func applyServerBatch(
        saves: [ParsedServerRecord],
        deletions: [(type: SyncRecordType, id: String)]
    ) async {
        let sortedSaves = Self.sortedParentsFirst(saves)
        let sortedDeletions = deletions.sorted {
            Self.typeIndex($0.type) > Self.typeIndex($1.type) // children first
        }
        do {
            let outcome = try await database.applyServerChanges { apply in
                var orphaned: [ParsedServerRecord] = []
                var dropped: [PendingChange] = []
                for record in sortedSaves {
                    let pendingBefore = try PendingChange.fetchOne(apply.db, key: record.row.id)
                    switch try apply.applyWithMerge(record) {
                    case .orphaned:
                        orphaned.append(record)
                    case .applied:
                        if let pendingBefore {
                            dropped.append(pendingBefore)
                        }
                    case .keptLocal:
                        break
                    }
                }
                for deletion in sortedDeletions {
                    dropped += try apply.applyDeletion(type: deletion.type, id: deletion.id)
                }
                return BatchOutcome(orphaned: orphaned, droppedPending: dropped)
            }
            orphanBuffer += outcome.orphaned
            if !outcome.droppedPending.isEmpty {
                engine?.state.remove(
                    pendingRecordZoneChanges: outcome.droppedPending.map(\.enginePendingChange))
            }
            if !outcome.droppedPending.filter({ $0.changeKind == .save }).isEmpty {
                Log.sync.info("Server changes superseded \(outcome.droppedPending.count) queued local change(s) (LWW)")
            }
            await drainOrphans(fetchComplete: false)
        } catch {
            Log.sync.error("Applying fetched changes failed: \(String(describing: error))")
            setStatus(.error(message: "couldn't apply changes from iCloud"))
        }
    }

    /// Retries buffered FK orphans. Mid-fetch, whatever still fails keeps
    /// waiting; once the fetch is complete, an item missing only its
    /// category is salvaged without the reference, and anything else is
    /// dropped with a log (its parent is genuinely gone).
    func drainOrphans(fetchComplete: Bool) async {
        guard !orphanBuffer.isEmpty else { return }
        let buffer = Self.sortedParentsFirst(orphanBuffer)
        orphanBuffer = []
        var still: [ParsedServerRecord]
        do {
            still = try await database.applyServerChanges { apply in
                var remaining: [ParsedServerRecord] = []
                for record in buffer {
                    if try apply.applyWithMerge(record) == .orphaned {
                        remaining.append(record)
                    }
                }
                return remaining
            }
        } catch {
            Log.sync.error("Orphan retry failed: \(String(describing: error))")
            still = buffer
        }
        guard fetchComplete else {
            orphanBuffer = still
            return
        }

        var droppedRecords: [ParsedServerRecord] = []
        var salvage: [ParsedServerRecord] = []
        for record in still {
            if case .item(var item) = record.row, item.categoryId != nil {
                item.categoryId = nil
                salvage.append(ParsedServerRecord(row: .item(item), systemFields: record.systemFields))
            } else {
                droppedRecords.append(record)
            }
        }
        if !salvage.isEmpty {
            let toApply = salvage
            let unsalvageable = try? await database.applyServerChanges { apply in
                var remaining: [ParsedServerRecord] = []
                for record in toApply {
                    if try apply.applyWithMerge(record) == .orphaned {
                        remaining.append(record)
                    }
                }
                return remaining
            }
            droppedRecords += unsalvageable ?? toApply
        }
        if !droppedRecords.isEmpty {
            Log.sync.warning("Dropped \(droppedRecords.count) fetched record(s) whose parent no longer exists")
            let receipts = droppedRecords
            try? await database.writer.write { db in
                for record in receipts {
                    try SyncEvent.append(
                        db, kind: .serverRecordDropped,
                        recordType: record.row.recordType, recordId: record.row.id,
                        summary: "\(record.row.displayName) — arrived from iCloud without a surviving parent and was not applied.")
                }
            }
        }
        orphanBuffer = []
    }

    func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) async {
        let saved = event.savedRecords.map { record in
            SavedSnapshot(
                id: record.recordID.recordName,
                type: SyncRecordType(rawValue: record.recordType),
                systemFields: record.encodedSystemFields(),
                sentUpdatedAt: record["updated_at"] as? Date)
        }
        let deletedIDs = event.deletedRecordIDs.map(\.recordName)
        do {
            try await database.writer.write { [saved, deletedIDs] db in
                for snapshot in saved {
                    guard let type = snapshot.type else { continue }
                    try RecordMetadata(
                        recordId: snapshot.id,
                        recordType: type,
                        systemFields: snapshot.systemFields
                    ).insert(db, onConflict: .replace)
                    guard let pending = try PendingChange.fetchOne(db, key: snapshot.id),
                          pending.changeKind == .save else { continue }
                    // If the row was edited again while this save was in
                    // flight, its stamp is newer than what we sent — keep it
                    // queued so the newer edit still uploads.
                    let row = try SyncedRow.fetch(db, type: type, id: snapshot.id)
                    if let rowUpdatedAt = row?.updatedAt,
                       let sent = snapshot.sentUpdatedAt,
                       rowUpdatedAt > sent.addingTimeInterval(0.0005) {
                        continue
                    }
                    try pending.delete(db)
                }
                for id in deletedIDs {
                    if let pending = try PendingChange.fetchOne(db, key: id),
                       pending.changeKind == .delete {
                        try pending.delete(db)
                    }
                    _ = try RecordMetadata.deleteOne(db, key: id)
                }
            }
        } catch {
            Log.sync.error("Recording sent changes failed: \(String(describing: error))")
        }

        for failure in event.failedRecordSaves {
            await handleFailedSave(failure)
        }
        for (recordID, error) in event.failedRecordDeletes {
            await handleFailedDelete(recordID, error)
        }
    }

    func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) async {
        let record = failure.record
        let error = failure.error
        let id = record.recordID.recordName
        switch error.code {
        case .serverRecordChanged:
            guard let serverRecord = error.serverRecord else {
                Log.sync.error("serverRecordChanged without a server record for \(id)")
                return
            }
            await resolveConflict(serverRecord: serverRecord)
        case .zoneNotFound:
            await recoverFromMissingZone(context: "record save")
        case .unknownItem:
            // Deleted server-side while our edit was in flight. Deletion wins
            // (the same rule as inbound deletes); the fetch delivers the
            // deletion for the local row.
            Log.sync.warning("Dropping local save for \(id): record was deleted on the server")
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            let type = SyncRecordType(rawValue: record.recordType)
            try? await database.writer.write { db in
                _ = try PendingChange.deleteOne(db, key: id)
                _ = try RecordMetadata.deleteOne(db, key: id)
                if let type {
                    let name = try SyncedRow.fetch(db, type: type, id: id)?.displayName ?? id
                    try SyncEvent.append(
                        db, kind: .localEditDroppedByDelete, recordType: type, recordId: id,
                        summary: "\(name) — deleted on another device while you had unsent changes; your edit was discarded.")
                }
            }
        case .networkFailure, .networkUnavailable, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .notAuthenticated:
            // Transient — the engine retries on its own; the queue row stays.
            Log.sync.info("Transient save failure for \(id): \(error.code.rawValue)")
        default:
            Log.sync.error("Unhandled save failure for \(id): \(String(describing: error))")
        }
    }

    /// `serverRecordChanged`: another device won the race to this record.
    /// LWW decides (D10): if our row is newer we re-apply our values on top
    /// of the server's change tag and re-send; otherwise the server copy is
    /// applied locally and our stale save is dropped.
    func resolveConflict(serverRecord: CKRecord) async {
        let recordID = serverRecord.recordID
        let parsed: ParsedServerRecord
        do {
            parsed = try RecordMapper.parse(serverRecord)
        } catch {
            // The server copy is malformed (Console experiment?). Adopt its
            // change tag and re-send local truth over it.
            Log.sync.warning("Conflict with unparseable server record \(recordID.recordName); keeping local values")
            guard let type = SyncRecordType(rawValue: serverRecord.recordType) else { return }
            let systemFields = serverRecord.encodedSystemFields()
            try? await database.writer.write { db in
                try RecordMetadata(
                    recordId: recordID.recordName, recordType: type, systemFields: systemFields
                ).insert(db, onConflict: .replace)
            }
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return
        }
        do {
            let outcome = try await database.applyServerChanges { apply in
                let pendingBefore = try PendingChange.fetchOne(apply.db, key: parsed.row.id)
                let result = try apply.applyWithMerge(parsed)
                return ConflictOutcome(result: result, pendingBefore: pendingBefore)
            }
            switch outcome.result {
            case .keptLocal:
                Log.sync.info("Conflict on \(parsed.row.id): local edit is newer, re-sending")
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                // A send-conflict is a true two-device divergence (unlike
                // routine fetch echoes), so the winning side gets a receipt
                // too — that's what makes LWW verifiable from either phone.
                let row = parsed.row
                try? await database.writer.write { db in
                    let localName = try SyncedRow
                        .fetch(db, type: row.recordType, id: row.id)?.displayName
                    try SyncEvent.append(
                        db, kind: .localEditWon,
                        recordType: row.recordType, recordId: row.id,
                        summary: "\(localName ?? row.displayName) — edited on two devices; your more recent change won.")
                }
            case .applied:
                Log.sync.info("Conflict on \(parsed.row.id): server edit is newer, accepted")
                if let pending = outcome.pendingBefore {
                    engine?.state.remove(pendingRecordZoneChanges: [pending.enginePendingChange])
                }
            case .orphaned:
                // Parent hasn't reached us yet — buffer and pull.
                orphanBuffer.append(parsed)
                fetchSoon()
            }
        } catch {
            Log.sync.error("Conflict resolution for \(parsed.row.id) failed: \(String(describing: error))")
        }
    }

    func handleFailedDelete(_ recordID: CKRecord.ID, _ error: CKError) async {
        let id = recordID.recordName
        switch error.code {
        case .unknownItem:
            // Already gone server-side — as good as done.
            engine?.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            try? await database.writer.write { db in
                if let pending = try PendingChange.fetchOne(db, key: id),
                   pending.changeKind == .delete {
                    try pending.delete(db)
                }
                _ = try RecordMetadata.deleteOne(db, key: id)
            }
        case .zoneNotFound:
            await recoverFromMissingZone(context: "record delete")
        case .networkFailure, .networkUnavailable, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .notAuthenticated:
            Log.sync.info("Transient delete failure for \(id): \(error.code.rawValue)")
        default:
            Log.sync.error("Unhandled delete failure for \(id): \(String(describing: error))")
        }
    }

    func handleSentDatabaseChanges(_ event: CKSyncEngine.Event.SentDatabaseChanges) {
        for zone in event.savedZones where zone.zoneID.zoneName == RecordMapper.zoneName {
            Log.sync.info("Household zone saved")
        }
        for failure in event.failedZoneSaves {
            Log.sync.error("Zone save failed: \(String(describing: failure.error))")
        }
    }

    /// Zone deleted / data purged / zoneNotFound: the server no longer has
    /// our records, so every archived change tag is void. Recreate the zone
    /// and re-queue the whole catalog. Guarded so a burst of per-record
    /// zoneNotFound failures runs one recovery, not a loop — and the engine's
    /// own send scheduling paces any retry after a failed recovery.
    func recoverFromMissingZone(context: String) async {
        guard !isRecoveringZone else { return }
        isRecoveringZone = true
        defer { isRecoveringZone = false }
        Log.sync.warning("Household zone missing (\(context)); recreating and re-uploading")
        do {
            try await database.writer.write { db in
                try RecordMetadata.deleteAll(db)
                // Deletes aimed at records the vanished zone held are moot.
                try db.execute(sql: "DELETE FROM pending_changes WHERE change_kind = 'delete'")
                try SyncBackfill.enqueueUnsyncedRows(db)
                try SyncEvent.append(
                    db, kind: .zoneRecovered, recordType: nil, recordId: nil,
                    summary: "iCloud data for this app was missing or reset — rebuilding it from this device's catalog.")
            }
            if let engine {
                let staleDeletes = engine.state.pendingRecordZoneChanges.filter {
                    if case .deleteRecord = $0 { return true }
                    return false
                }
                engine.state.remove(pendingRecordZoneChanges: staleDeletes)
                engine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneName: RecordMapper.zoneName)),
                ])
            }
        } catch {
            Log.sync.error("Zone recovery failed: \(String(describing: error))")
        }
    }

    // MARK: Helpers

    static func sortedParentsFirst(_ records: [ParsedServerRecord]) -> [ParsedServerRecord] {
        records.sorted { typeIndex($0.row.recordType) < typeIndex($1.row.recordType) }
    }

    static func typeIndex(_ type: SyncRecordType) -> Int {
        SyncRecordType.parentsFirst.firstIndex(of: type) ?? SyncRecordType.parentsFirst.count
    }
}

// MARK: - Support types

private struct BatchOutcome: Sendable {
    var orphaned: [ParsedServerRecord]
    var droppedPending: [PendingChange]
}

private struct ConflictOutcome: Sendable {
    var result: ServerApply.ApplyOutcome
    var pendingBefore: PendingChange?
}

private struct SavedSnapshot: Sendable {
    var id: String
    var type: SyncRecordType?
    var systemFields: Data
    var sentUpdatedAt: Date?
}

extension PendingChange {
    var ckRecordID: CKRecord.ID {
        CKRecord.ID(recordName: recordId, zoneID: RecordMapper.zoneID)
    }

    var enginePendingChange: CKSyncEngine.PendingRecordZoneChange {
        switch changeKind {
        case .save: .saveRecord(ckRecordID)
        case .delete: .deleteRecord(ckRecordID)
        }
    }
}
