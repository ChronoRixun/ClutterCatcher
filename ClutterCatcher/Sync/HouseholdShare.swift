import CloudKit
import Foundation

/// Zone-wide CKShare plumbing (D8, M3-D): the one share on the `Household`
/// zone, its roster, and its local archive. The share record is saved and
/// deleted through the plain database API, not the sync engine — the engine
/// only ever sends records from `pending_changes`, so it can't fight these
/// writes; inbound, `SyncCoordinator` routes fetched CKShare records here
/// for roster refresh instead of the catalog apply path.
enum HouseholdShare {
    static let title = "ClutterCatcher Household"

    /// The fixed record ID of a zone-wide share in a given zone.
    static func shareRecordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
    }

    /// A fresh zone-wide share for the Household zone: read-write for the
    /// family (D8), no public access.
    static func makeShare(zoneID: CKRecordZone.ID) -> CKShare {
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = title
        share.publicPermission = .none
        return share
    }

    // MARK: Roster (D11)

    /// The share's participants as roster rows. Entries without a resolvable
    /// user record name or display name are skipped — `created_by` rendering
    /// simply shows nothing for them.
    static func roster(from share: CKShare) -> [Participant] {
        share.participants.compactMap { participant in
            guard let userRecordName = participant.userIdentity.userRecordID?.recordName,
                  let displayName = displayName(for: participant) else {
                return nil
            }
            return Participant(userRecordName: userRecordName, displayName: displayName)
        }
    }

    static func displayName(for participant: CKShare.Participant) -> String? {
        let identity = participant.userIdentity
        if let components = identity.nameComponents {
            let formatted = PersonNameComponentsFormatter
                .localizedString(from: components, style: .default)
            if !formatted.isEmpty {
                return formatted
            }
        }
        return identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber
    }

    // MARK: Local archive

    /// Full keyed archive (not just system fields — participants ride along),
    /// so the Family screen can reflect "sharing is on, with whom" straight
    /// from the database before a live refetch lands.
    static func archive(_ share: CKShare) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: share, requiringSecureCoding: true)
    }

    static func unarchive(_ data: Data) -> CKShare? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKShare.self, from: data)
    }
}
