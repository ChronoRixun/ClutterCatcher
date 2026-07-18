import Foundation
import GRDB

/// One entry in the sync activity log (`sync_events` table, local-only, v2).
///
/// These are the receipts behind the "nothing lost silently" promise (D10):
/// whenever last-write-wins overwrites or drops something, or sync has to
/// rebuild state, a self-contained human-readable summary lands here for the
/// Settings → Sync Activity screen. Summaries carry the row's name at event
/// time, because the row itself may be gone by the time anyone reads them.
struct SyncEvent: Identifiable, Equatable, Sendable, Codable,
    FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "sync_events"

    enum Kind: String, Codable, Sendable {
        /// A queued local change lost LWW to a newer edit from another device.
        case localEditOverwritten
        /// A true send-conflict where the local edit was newer and won.
        case localEditWon
        /// A remote delete landed while a local edit was still unsent.
        case localEditDroppedByDelete
        /// A fetched record could not be applied (parent gone / unreadable).
        case serverRecordDropped
        /// The Household zone vanished; it was recreated and re-uploaded.
        case zoneRecovered
    }

    var id: Int64?
    var occurredAt: Date
    var kind: Kind
    var recordType: SyncRecordType?
    var recordId: String?
    var summary: String

    enum CodingKeys: String, CodingKey {
        case id
        case occurredAt = "occurred_at"
        case kind
        case recordType = "record_type"
        case recordId = "record_id"
        case summary
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension SyncEvent {
    /// The log keeps this many entries; older ones are pruned on append.
    static let keepCount = 200

    static func append(
        _ db: Database,
        kind: Kind,
        recordType: SyncRecordType?,
        recordId: String?,
        summary: String
    ) throws {
        var event = SyncEvent(
            id: nil,
            occurredAt: Date(),
            kind: kind,
            recordType: recordType,
            recordId: recordId,
            summary: summary)
        try event.insert(db)
        try db.execute(
            sql: "DELETE FROM sync_events WHERE id <= (SELECT MAX(id) FROM sync_events) - ?",
            arguments: [keepCount])
    }
}
