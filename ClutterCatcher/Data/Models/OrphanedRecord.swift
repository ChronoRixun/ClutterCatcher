import Foundation
import GRDB

/// One buffered FK orphan (`orphaned_records` table, local-only, v3): a
/// fetched server record whose parent row hasn't arrived yet, persisted so a
/// crash between a fetch batch and the drain can't lose it (M3-G). The
/// payload is the JSON-encoded `SyncedRow`; `system_fields` is kept alongside
/// so the drained record re-enters the apply path as a full
/// `ParsedServerRecord`.
struct OrphanedRecord: Equatable, Sendable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "orphaned_records"

    var recordId: String
    var recordType: SyncRecordType
    var payload: Data
    var systemFields: Data
    var bufferedAt: Date

    enum CodingKeys: String, CodingKey {
        case recordId = "record_id"
        case recordType = "record_type"
        case payload
        case systemFields = "system_fields"
        case bufferedAt = "buffered_at"
    }
}

extension OrphanedRecord {
    init(parsed: ParsedServerRecord, bufferedAt: Date) throws {
        self.init(
            recordId: parsed.row.id,
            recordType: parsed.row.recordType,
            payload: try JSONEncoder().encode(parsed.row),
            systemFields: parsed.systemFields,
            bufferedAt: bufferedAt)
    }

    /// nil if the payload can't be decoded (a schema drift between writes and
    /// reads — the row would re-arrive on its next server change anyway).
    func parsedServerRecord() -> ParsedServerRecord? {
        guard let row = try? JSONDecoder().decode(SyncedRow.self, from: payload) else {
            return nil
        }
        return ParsedServerRecord(row: row, systemFields: systemFields)
    }

    /// Buffers records, newest write winning for a given id.
    static func buffer(_ db: Database, records: [ParsedServerRecord], at date: Date) throws {
        for record in records {
            try OrphanedRecord(parsed: record, bufferedAt: date)
                .insert(db, onConflict: .replace)
        }
    }

    /// Every buffered record that still decodes; undecodable rows are pruned,
    /// so this needs a write connection.
    static func loadAll(_ db: Database) throws -> [ParsedServerRecord] {
        var parsed: [ParsedServerRecord] = []
        for orphan in try OrphanedRecord.fetchAll(db) {
            if let record = orphan.parsedServerRecord() {
                parsed.append(record)
            } else {
                _ = try OrphanedRecord.deleteOne(db, key: orphan.recordId)
            }
        }
        return parsed
    }
}
