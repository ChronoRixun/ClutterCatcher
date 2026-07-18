import CloudKit
import Foundation
import Testing
@testable import ClutterCatcher

/// Table ↔ CKRecord mapping (plan §3.2): recordName = row UUID, zone
/// `Household`, all fields mapped except `created_by` (derived, never stored
/// in the record — D11).
@Suite struct RecordMappingTests {
    private let created = Date(timeIntervalSinceReferenceDate: 700_000_000.123)
    private let updated = Date(timeIntervalSinceReferenceDate: 700_000_100.456)

    // MARK: Round-trips

    @Test func roomRoundTrips() throws {
        let room = Room(
            id: AppDatabase.newID(), name: "Garage", sortOrder: 3, icon: "car",
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .room(room), systemFields: nil)
        #expect(record.recordType == "Room")
        #expect(record.recordID.recordName == room.id)
        #expect(record.recordID.zoneID.zoneName == "Household")
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .room(room))
    }

    @Test func categoryRoundTrips() throws {
        let category = Category(
            id: AppDatabase.newID(), name: "Tools", colorToken: "orange",
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .category(category), systemFields: nil)
        #expect(record.recordType == "Category")
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .category(category))
    }

    @Test func containerRoundTrips() throws {
        let container = Container(
            id: AppDatabase.newID(), roomId: AppDatabase.newID(), name: "Tool Bin",
            notes: "top shelf", labelSlot: 12,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .container(container), systemFields: nil)
        #expect(record.recordType == "Container")
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .container(container))
    }

    @Test func containerRoundTripsWithNilOptionals() throws {
        let container = Container(
            id: AppDatabase.newID(), roomId: AppDatabase.newID(), name: "Bin",
            notes: nil, labelSlot: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .container(container), systemFields: nil)
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .container(container))
    }

    @Test func itemRoundTrips() throws {
        let item = Item(
            id: AppDatabase.newID(), containerId: AppDatabase.newID(), name: "Wrench",
            quantity: 4, notes: "metric", categoryId: AppDatabase.newID(), photoAssetRef: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .item(item), systemFields: nil)
        #expect(record.recordType == "Item")
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .item(item))
    }

    @Test func createdByStaysOutOfTheRecord() {
        var room = Room(
            id: AppDatabase.newID(), name: "Garage", sortOrder: 0, icon: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        room.createdBy = "SOMEONE"
        let record = RecordMapper.record(for: .room(room), systemFields: nil)
        #expect(record["created_by"] == nil)
    }

    @Test func parsedRowExposesTypeIdAndUpdatedAt() throws {
        let item = Item(
            id: AppDatabase.newID(), containerId: AppDatabase.newID(), name: "Wrench",
            quantity: 1, notes: nil, categoryId: nil, photoAssetRef: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .item(item), systemFields: nil)
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row.recordType == .item)
        #expect(parsed.row.id == item.id)
        #expect(parsed.row.updatedAt == updated)
    }

    // MARK: Malformed server records

    @Test func parseRejectsUnknownRecordType() {
        let record = CKRecord(
            recordType: "Gadget",
            recordID: CKRecord.ID(recordName: AppDatabase.newID(), zoneID: RecordMapper.zoneID))
        #expect(throws: (any Error).self) {
            try RecordMapper.parse(record)
        }
    }

    @Test func parseRejectsMissingName() {
        let record = CKRecord(
            recordType: "Room",
            recordID: CKRecord.ID(recordName: AppDatabase.newID(), zoneID: RecordMapper.zoneID))
        #expect(throws: (any Error).self) {
            try RecordMapper.parse(record)
        }
    }

    @Test func parseRejectsItemWithoutContainerReference() {
        let record = CKRecord(
            recordType: "Item",
            recordID: CKRecord.ID(recordName: AppDatabase.newID(), zoneID: RecordMapper.zoneID))
        record["name"] = "Wrench"
        #expect(throws: (any Error).self) {
            try RecordMapper.parse(record)
        }
    }

    @Test func parseDefaultsMissingScalars() throws {
        let record = CKRecord(
            recordType: "Item",
            recordID: CKRecord.ID(recordName: AppDatabase.newID(), zoneID: RecordMapper.zoneID))
        record["name"] = "Wrench"
        record["container_id"] = AppDatabase.newID()
        let parsed = try RecordMapper.parse(record)
        guard case .item(let item) = parsed.row else {
            Issue.record("expected an item")
            return
        }
        #expect(item.quantity == 1)
        #expect(item.createdAt == Date(timeIntervalSince1970: 0))
        #expect(item.updatedAt == Date(timeIntervalSince1970: 0))
    }

    // MARK: System fields

    @Test func systemFieldsRoundTripPreservesIdentityNotUserFields() throws {
        let recordID = CKRecord.ID(recordName: AppDatabase.newID(), zoneID: RecordMapper.zoneID)
        let original = CKRecord(recordType: "Room", recordID: recordID)
        original["name"] = "Garage"
        let data = original.encodedSystemFields()
        let decoded = try #require(CKRecord.decodeSystemFields(from: data))
        #expect(decoded.recordID == recordID)
        #expect(decoded.recordType == "Room")
        #expect(decoded["name"] == nil, "system-fields archive must not carry user fields")
    }

    @Test func mapperBuildsOnArchivedSystemFields() {
        let room = Room(
            id: AppDatabase.newID(), name: "Garage", sortOrder: 0, icon: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let recordID = CKRecord.ID(recordName: room.id, zoneID: RecordMapper.zoneID)
        let base = CKRecord(recordType: "Room", recordID: recordID)
        let rebuilt = RecordMapper.record(for: .room(room), systemFields: base.encodedSystemFields())
        #expect(rebuilt.recordID == recordID)
        #expect(rebuilt["name"] as? String == "Garage")
    }

    @Test func mapperIgnoresMismatchedSystemFields() {
        // Metadata for a different record id (corrupt bookkeeping) must not
        // hijack the outbound record's identity.
        let room = Room(
            id: AppDatabase.newID(), name: "Garage", sortOrder: 0, icon: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let otherID = CKRecord.ID(recordName: AppDatabase.newID(), zoneID: RecordMapper.zoneID)
        let other = CKRecord(recordType: "Room", recordID: otherID)
        let rebuilt = RecordMapper.record(for: .room(room), systemFields: other.encodedSystemFields())
        #expect(rebuilt.recordID.recordName == room.id)
    }

    @Test func decodeSystemFieldsRejectsGarbage() {
        #expect(CKRecord.decodeSystemFields(from: Data([0xDE, 0xAD, 0xBE, 0xEF])) == nil)
    }
}
