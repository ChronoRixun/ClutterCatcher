import Foundation
import GRDB

/// One outbound change waiting to reach CloudKit (`pending_changes` table,
/// local-only). The primary key is the record id, so re-editing a row before
/// it uploads keeps a single queue entry and the latest kind wins — a delete
/// queued after an unsent save becomes just a delete.
struct PendingChange: Equatable, Sendable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pending_changes"

    enum Kind: String, Codable, Sendable {
        case save
        case delete
    }

    var recordId: String
    var recordType: SyncRecordType
    var changeKind: Kind
    var queuedAt: Date

    enum CodingKeys: String, CodingKey {
        case recordId = "record_id"
        case recordType = "record_type"
        case changeKind = "change_kind"
        case queuedAt = "queued_at"
    }
}
