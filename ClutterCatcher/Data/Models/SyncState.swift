import Foundation
import GRDB

/// One serialized CKSyncEngine state blob (`sync_state` table, local-only).
/// M2 holds a single row for the private-database engine; M3 adds the
/// shared-database engine's row alongside it.
struct SyncState: Equatable, Sendable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_state"

    var key: String
    var data: Data
}

extension SyncState {
    /// The private-database engine's `CKSyncEngine.State.Serialization`.
    static let privateEngineKey = "privateEngine.state"
    /// The iCloud user record name this bookkeeping belongs to. A mismatch at
    /// startup means the Apple ID changed: engine state and record metadata
    /// are then invalid and get reset (the catalog itself stays).
    static let accountUserKey = "account.userRecordName"
}
