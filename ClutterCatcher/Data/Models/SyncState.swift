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
    /// The private-database engine's `CKSyncEngine.State.Serialization`
    /// (owner role).
    static let privateEngineKey = "privateEngine.state"
    /// The shared-database engine's serialization (participant role, M3).
    static let sharedEngineKey = "sharedEngine.state"
    /// JSON `SyncIdentityFingerprint` — the (account, environment) pair the
    /// sync bookkeeping is valid for. A mismatch of either component at
    /// startup resets engine state and record metadata (the catalog stays).
    static let identityKey = "sync.identity"
    /// M2's account-only predecessor of `identityKey` (DL25); read once for
    /// migration, then deleted.
    static let legacyAccountUserKey = "account.userRecordName"
    /// JSON `SyncRole` — this device's household role, set by onboarding,
    /// automatic owner adoption, or share acceptance.
    static let roleKey = "sync.role"
    /// Present (any value) while a participant is disconnected from the
    /// household (share revoked / zone gone). Cleared by re-acceptance.
    static let participantDisconnectedKey = "participant.disconnected"
    /// Full keyed archive of the household `CKShare` (owner role) — lets the
    /// Family screen reflect "sharing is on" before its live refetch lands.
    static let archivedShareKey = "share.archived"
}
