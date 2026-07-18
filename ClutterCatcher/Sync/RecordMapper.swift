import CloudKit
import Foundation

/// A server record decoded into local currency: the row values plus the
/// archived system fields that belong in `record_metadata` once applied.
struct ParsedServerRecord: Equatable, Sendable {
    var row: SyncedRow
    var systemFields: Data
}

/// Pure table ↔ CKRecord mapping (plan §3.2): recordName = row UUID, field
/// keys = the SQL column names. The `Household` zone's identity is dynamic
/// (M3-C): the owner's records live in their own zone, a participant's in a
/// zone owned by someone else — so the zone ID is threaded in from the one
/// place that resolves it (`SyncRole.zoneID`), never constructed here.
/// `created_by` never *leaves* in our record fields (D11) — inbound, it's
/// derived from CloudKit's own creator metadata.
enum RecordMapper {
    static let zoneName = "Household"

    enum MappingError: Error {
        case unknownRecordType(String)
        case missingField(String, recordType: String)
    }

    // MARK: Outbound (row → CKRecord)

    /// Builds the outbound record, on top of the archived system fields when
    /// the server has seen this record before (so the save carries the
    /// correct change tag), or fresh when it hasn't.
    static func record(for row: SyncedRow, systemFields: Data?, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = baseRecord(
            type: row.recordType, id: row.id, systemFields: systemFields, zoneID: zoneID)
        switch row {
        case .room(let room):
            record["name"] = room.name
            record["sort_order"] = room.sortOrder
            record["icon"] = room.icon
            record["created_at"] = room.createdAt
            record["updated_at"] = room.updatedAt
        case .category(let category):
            record["name"] = category.name
            record["color_token"] = category.colorToken
            record["created_at"] = category.createdAt
            record["updated_at"] = category.updatedAt
        case .container(let container):
            record["room_id"] = container.roomId
            record["name"] = container.name
            record["notes"] = container.notes
            record["label_slot"] = container.labelSlot
            record["created_at"] = container.createdAt
            record["updated_at"] = container.updatedAt
        case .item(let item):
            record["container_id"] = item.containerId
            record["name"] = item.name
            record["quantity"] = item.quantity
            record["notes"] = item.notes
            record["category_id"] = item.categoryId
            record["photo_asset_ref"] = item.photoAssetRef
            record["created_at"] = item.createdAt
            record["updated_at"] = item.updatedAt
        }
        return record
    }

    private static func baseRecord(
        type: SyncRecordType, id: String, systemFields: Data?, zoneID: CKRecordZone.ID
    ) -> CKRecord {
        if let systemFields,
           let restored = CKRecord.decodeSystemFields(from: systemFields),
           restored.recordType == type.rawValue,
           restored.recordID.recordName == id {
            return restored
        }
        return CKRecord(
            recordType: type.rawValue,
            recordID: CKRecord.ID(recordName: id, zoneID: zoneID))
    }

    // MARK: Inbound (CKRecord → row)

    static func parse(_ record: CKRecord) throws -> ParsedServerRecord {
        guard let type = SyncRecordType(rawValue: record.recordType) else {
            throw MappingError.unknownRecordType(record.recordType)
        }
        let row = try parsedRow(type: type, record: record)
        return ParsedServerRecord(row: row, systemFields: record.encodedSystemFields())
    }

    private static func parsedRow(type: SyncRecordType, record: CKRecord) throws -> SyncedRow {
        let id = record.recordID.recordName
        let name = try requiredString("name", record)
        // Records written by ClutterCatcher always carry both dates; the
        // epoch fallback keeps a hand-made Console record from killing the
        // fetch loop (it then loses every LWW comparison instead).
        let createdAt = record["created_at"] as? Date ?? Date(timeIntervalSince1970: 0)
        let updatedAt = record["updated_at"] as? Date ?? Date(timeIntervalSince1970: 0)
        // D11: created_by is CloudKit's own creator metadata, never one of
        // our record fields. `__defaultOwner__` means the zone owner;
        // Participant.displayName owns the mapping to a human name.
        let createdBy = record.creatorUserRecordID?.recordName

        switch type {
        case .room:
            return .room(Room(
                id: id,
                name: name,
                sortOrder: record["sort_order"] as? Int ?? 0,
                icon: record["icon"] as? String,
                createdAt: createdAt,
                updatedAt: updatedAt,
                createdBy: createdBy))
        case .category:
            return .category(Category(
                id: id,
                name: name,
                colorToken: record["color_token"] as? String ?? "gray",
                createdAt: createdAt,
                updatedAt: updatedAt,
                createdBy: createdBy))
        case .container:
            let roomId = try requiredString("room_id", record)
            return .container(Container(
                id: id,
                roomId: roomId,
                name: name,
                notes: record["notes"] as? String,
                labelSlot: record["label_slot"] as? Int,
                createdAt: createdAt,
                updatedAt: updatedAt,
                createdBy: createdBy))
        case .item:
            let containerId = try requiredString("container_id", record)
            return .item(Item(
                id: id,
                containerId: containerId,
                name: name,
                quantity: record["quantity"] as? Int ?? 1,
                notes: record["notes"] as? String,
                categoryId: record["category_id"] as? String,
                photoAssetRef: record["photo_asset_ref"] as? String,
                createdAt: createdAt,
                updatedAt: updatedAt,
                createdBy: createdBy))
        }
    }

    private static func requiredString(_ key: String, _ record: CKRecord) throws -> String {
        guard let value = record[key] as? String else {
            throw MappingError.missingField(key, recordType: record.recordType)
        }
        return value
    }
}
