import CloudKit
import Foundation
import GRDB

/// One household member (`participants` table, local-only, v3): the opaque
/// CloudKit user record name mapped to a human name (D11). Refreshed from
/// `CKShare.participants` whenever the share is fetched; never synced.
struct Participant: Equatable, Sendable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "participants"

    var userRecordName: String
    var displayName: String

    enum CodingKeys: String, CodingKey {
        case userRecordName = "user_record_name"
        case displayName = "display_name"
    }
}

extension Participant {
    /// Replaces the whole roster — the share is the source of truth, so
    /// removed participants drop out here too.
    static func replaceAll(_ db: Database, with roster: [Participant]) throws {
        try Participant.deleteAll(db)
        for participant in roster {
            try participant.insert(db, onConflict: .replace)
        }
    }

    /// Resolves a `created_by` value to a display name (M3-F), or nil when it
    /// can't be resolved — callers then show nothing rather than an opaque ID.
    ///
    /// `CKCurrentUserDefaultName` ("`__defaultOwner__`") names the *zone
    /// owner*: on the owner's device that's "You"; on a participant's device
    /// it resolves to the owner's roster name. Any other value is "You" when
    /// it matches this device's stored user record name, else a roster lookup.
    static func displayName(_ db: Database, createdBy: String?) throws -> String? {
        guard let createdBy else { return nil }
        let role = try SyncRole.load(db)
        if createdBy == CKCurrentUserDefaultName {
            switch role {
            case .owner, nil:
                return "You"
            case .participant(let zoneOwnerName):
                return try Participant.fetchOne(db, key: zoneOwnerName)?.displayName
            }
        }
        if let own = try SyncIdentityBookkeeping.storedUserRecordName(db),
           own == createdBy {
            return "You"
        }
        return try Participant.fetchOne(db, key: createdBy)?.displayName
    }
}
