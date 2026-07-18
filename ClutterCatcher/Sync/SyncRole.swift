import CloudKit
import Foundation
import GRDB

/// This device's place in the household (M3, D8): the owner runs the
/// private-database engine against a zone it owns; a participant runs the
/// shared-database engine against the owner's zone. Persisted in
/// `sync_state`; absent until first-launch onboarding (or an existing
/// data-bearing install's automatic owner adoption) decides it.
enum SyncRole: Equatable, Sendable, Codable {
    case owner
    case participant(zoneOwnerName: String)

    var isOwner: Bool {
        if case .owner = self { return true }
        return false
    }

    /// The `Household` zone this role syncs against — the single source of
    /// zone identity. No call site constructs a zone ID any other way (M3-C).
    var zoneID: CKRecordZone.ID {
        switch self {
        case .owner:
            CKRecordZone.ID(
                zoneName: RecordMapper.zoneName, ownerName: CKCurrentUserDefaultName)
        case .participant(let zoneOwnerName):
            CKRecordZone.ID(
                zoneName: RecordMapper.zoneName, ownerName: zoneOwnerName)
        }
    }
}

// MARK: - Persistence

extension SyncRole {
    static func load(_ db: Database) throws -> SyncRole? {
        guard let stored = try SyncState.fetchOne(db, key: SyncState.roleKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SyncRole.self, from: stored.data)
    }

    func save(_ db: Database) throws {
        let data = try JSONEncoder().encode(self)
        try SyncState(key: SyncState.roleKey, data: data)
            .insert(db, onConflict: .replace)
    }
}
