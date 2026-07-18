import Foundation
import GRDB

/// First-start upload seeding: rows that predate the sync engine (Owen's
/// real M1 catalog, plus anything written while signed out) have no
/// `record_metadata`, meaning the server has never acked them — enqueue them
/// all. Runs on every engine start; a no-op once everything is acked.
enum SyncBackfill {
    /// Returns how many rows were newly enqueued.
    @discardableResult
    static func enqueueUnsyncedRows(_ db: Database) throws -> Int {
        let queuedAt = Date()
        var enqueued = 0
        for type in SyncRecordType.parentsFirst {
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM \(type.tableName)
                WHERE id NOT IN (SELECT record_id FROM record_metadata)
                """)
            for id in ids {
                // Never clobber an already-queued change — its kind and
                // queue time are the truth.
                let alreadyQueued = try PendingChange.exists(db, key: id)
                guard !alreadyQueued else { continue }
                try PendingChange(
                    recordId: id, recordType: type, changeKind: .save, queuedAt: queuedAt
                ).insert(db)
                enqueued += 1
            }
        }
        return enqueued
    }
}
