import CloudKit
import Foundation
import Testing
@testable import ClutterCatcher

/// Table ↔ CKRecord mapping (plan §3.2): recordName = row UUID, zone
/// `Household`, all fields mapped except `created_by` (derived, never stored
/// in the record — D11).
@Suite struct RecordMappingTests {
    /// The owner's zone — mapping is zone-agnostic (M3-C), so these tests
    /// pin the owner variant and DynamicZoneTests covers the participant one.
    private static let zone = SyncRole.owner.zoneID
    private let created = Date(timeIntervalSinceReferenceDate: 700_000_000.123)
    private let updated = Date(timeIntervalSinceReferenceDate: 700_000_100.456)

    // MARK: Round-trips

    @Test func roomRoundTrips() throws {
        let room = Room(
            id: AppDatabase.newID(), name: "Garage", sortOrder: 3, icon: "car",
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .room(room), systemFields: nil, zoneID: Self.zone)
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
        let record = RecordMapper.record(for: .category(category), systemFields: nil, zoneID: Self.zone)
        #expect(record.recordType == "Category")
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .category(category))
    }

    @Test func containerRoundTrips() throws {
        let container = Container(
            id: AppDatabase.newID(), roomId: AppDatabase.newID(), name: "Tool Bin",
            notes: "top shelf", labelSlot: 12, coverItemId: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .container(container), systemFields: nil, zoneID: Self.zone)
        #expect(record.recordType == "Container")
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .container(container))
    }

    @Test func containerRoundTripsWithNilOptionals() throws {
        let container = Container(
            id: AppDatabase.newID(), roomId: AppDatabase.newID(), name: "Bin",
            notes: nil, labelSlot: nil, coverItemId: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .container(container), systemFields: nil, zoneID: Self.zone)
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .container(container))
    }

    @Test func itemRoundTrips() throws {
        let item = Item(
            id: AppDatabase.newID(), containerId: AppDatabase.newID(), name: "Wrench",
            quantity: 4, notes: "metric", categoryId: AppDatabase.newID(), photoAssetRef: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .item(item), systemFields: nil, zoneID: Self.zone)
        #expect(record.recordType == "Item")
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .item(item))
    }

    // MARK: M6 — photos & cover

    /// Outbound: the item keeps its `photo_asset_ref` string field (P6) *and*,
    /// given a resolved local file URL, gains a `photo` CKAsset (P7). Inbound
    /// parse ignores the CKAsset (P8) yet round-trips the id, and the parsed
    /// record stays the pure `Equatable` value the orphan table depends on.
    @Test func itemPhotoAttachesCKAssetAndRoundTripsPurely() throws {
        let item = Item(
            id: AppDatabase.newID(), containerId: AppDatabase.newID(), name: "Drill",
            quantity: 1, notes: nil, categoryId: nil, photoAssetRef: "REF-PHOTO",
            createdAt: created, updatedAt: updated, createdBy: nil)
        // A real temp file so CKAsset has a valid fileURL.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppDatabase.newID()).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let record = RecordMapper.record(
            for: .item(item), systemFields: nil, zoneID: Self.zone, assetFileURL: tempURL)
        #expect(record["photo_asset_ref"] as? String == "REF-PHOTO")
        let asset = record["photo"] as? CKAsset
        #expect(asset != nil, "a local file URL attaches the photo CKAsset")
        #expect(asset?.fileURL == tempURL)

        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .item(item), "the asset copy is coordinator-level; parse stays pure")
    }

    /// Outbound with no local file (bytes not on this device): the ref rides
    /// but the asset field is left untouched, so a metadata-only edit never
    /// clears the household's asset (§4).
    @Test func itemWithoutLocalFileOmitsCKAsset() throws {
        let item = Item(
            id: AppDatabase.newID(), containerId: AppDatabase.newID(), name: "Drill",
            quantity: 1, notes: nil, categoryId: nil, photoAssetRef: "REF-PHOTO",
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .item(item), systemFields: nil, zoneID: Self.zone)
        #expect(record["photo_asset_ref"] as? String == "REF-PHOTO")
        #expect(record["photo"] == nil, "no bytes on device → the asset field is left alone")
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .item(item))
    }

    @Test func containerCoverItemIdRoundTrips() throws {
        let container = Container(
            id: AppDatabase.newID(), roomId: AppDatabase.newID(), name: "Bin",
            notes: nil, labelSlot: nil, coverItemId: "COVER-ITEM-ID",
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .container(container), systemFields: nil, zoneID: Self.zone)
        #expect(record["cover_item_id"] as? String == "COVER-ITEM-ID")
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row == .container(container))
    }

    @Test func createdByStaysOutOfTheRecord() {
        var room = Room(
            id: AppDatabase.newID(), name: "Garage", sortOrder: 0, icon: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        room.createdBy = "SOMEONE"
        let record = RecordMapper.record(for: .room(room), systemFields: nil, zoneID: Self.zone)
        #expect(record["created_by"] == nil)
    }

    @Test func parsedRowExposesTypeIdAndUpdatedAt() throws {
        let item = Item(
            id: AppDatabase.newID(), containerId: AppDatabase.newID(), name: "Wrench",
            quantity: 1, notes: nil, categoryId: nil, photoAssetRef: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let record = RecordMapper.record(for: .item(item), systemFields: nil, zoneID: Self.zone)
        let parsed = try RecordMapper.parse(record)
        #expect(parsed.row.recordType == .item)
        #expect(parsed.row.id == item.id)
        #expect(parsed.row.updatedAt == updated)
    }

    // MARK: Malformed server records

    @Test func parseRejectsUnknownRecordType() {
        let record = CKRecord(
            recordType: "Gadget",
            recordID: CKRecord.ID(recordName: AppDatabase.newID(), zoneID: Self.zone))
        #expect(throws: (any Error).self) {
            try RecordMapper.parse(record)
        }
    }

    @Test func parseRejectsMissingName() {
        let record = CKRecord(
            recordType: "Room",
            recordID: CKRecord.ID(recordName: AppDatabase.newID(), zoneID: Self.zone))
        #expect(throws: (any Error).self) {
            try RecordMapper.parse(record)
        }
    }

    @Test func parseRejectsItemWithoutContainerReference() {
        let record = CKRecord(
            recordType: "Item",
            recordID: CKRecord.ID(recordName: AppDatabase.newID(), zoneID: Self.zone))
        record["name"] = "Wrench"
        #expect(throws: (any Error).self) {
            try RecordMapper.parse(record)
        }
    }

    @Test func parseDefaultsMissingScalars() throws {
        let record = CKRecord(
            recordType: "Item",
            recordID: CKRecord.ID(recordName: AppDatabase.newID(), zoneID: Self.zone))
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
        let recordID = CKRecord.ID(recordName: AppDatabase.newID(), zoneID: Self.zone)
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
        let recordID = CKRecord.ID(recordName: room.id, zoneID: Self.zone)
        let base = CKRecord(recordType: "Room", recordID: recordID)
        let rebuilt = RecordMapper.record(for: .room(room), systemFields: base.encodedSystemFields(), zoneID: Self.zone)
        #expect(rebuilt.recordID == recordID)
        #expect(rebuilt["name"] as? String == "Garage")
    }

    @Test func mapperIgnoresMismatchedSystemFields() {
        // Metadata for a different record id (corrupt bookkeeping) must not
        // hijack the outbound record's identity.
        let room = Room(
            id: AppDatabase.newID(), name: "Garage", sortOrder: 0, icon: nil,
            createdAt: created, updatedAt: updated, createdBy: nil)
        let otherID = CKRecord.ID(recordName: AppDatabase.newID(), zoneID: Self.zone)
        let other = CKRecord(recordType: "Room", recordID: otherID)
        let rebuilt = RecordMapper.record(for: .room(room), systemFields: other.encodedSystemFields(), zoneID: Self.zone)
        #expect(rebuilt.recordID.recordName == room.id)
    }

    @Test func decodeSystemFieldsRejectsGarbage() {
        #expect(CKRecord.decodeSystemFields(from: Data([0xDE, 0xAD, 0xBE, 0xEF])) == nil)
    }
}
