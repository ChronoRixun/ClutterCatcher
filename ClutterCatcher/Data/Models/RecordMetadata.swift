import Foundation
import GRDB

/// The archived CKRecord system fields for one synced row (`record_metadata`
/// table, local-only). Presence means the server has acked the record; the
/// blob carries the change tag every subsequent save must present
/// (plan §3.2 — see `CKRecord.encodedSystemFields`).
struct RecordMetadata: Equatable, Sendable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "record_metadata"

    var recordId: String
    var recordType: SyncRecordType
    var systemFields: Data

    enum CodingKeys: String, CodingKey {
        case recordId = "record_id"
        case recordType = "record_type"
        case systemFields = "system_fields"
    }
}
