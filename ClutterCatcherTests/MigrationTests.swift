import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

@Suite struct MigrationTests {
    @Test func freshDatabaseCreatesAllTables() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.read { db in
            for table in [
                "rooms", "categories", "containers", "items",
                "settings", "sync_state", "record_metadata", "pending_changes",
            ] {
                #expect(try db.tableExists(table), "missing table \(table)")
            }
        }
    }

    @Test func syncedTablesHaveExpectedColumns() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.read { db in
            let rooms = try db.columns(in: "rooms").map(\.name)
            #expect(Set(rooms).isSuperset(of: [
                "id", "name", "sort_order", "icon",
                "created_at", "updated_at", "created_by",
            ]))

            let containers = try db.columns(in: "containers").map(\.name)
            #expect(Set(containers).isSuperset(of: [
                "id", "room_id", "name", "notes", "label_slot",
                "created_at", "updated_at", "created_by",
            ]))

            let items = try db.columns(in: "items").map(\.name)
            #expect(Set(items).isSuperset(of: [
                "id", "container_id", "name", "quantity", "notes",
                "category_id", "photo_asset_ref",
                "created_at", "updated_at", "created_by",
            ]))

            let categories = try db.columns(in: "categories").map(\.name)
            #expect(Set(categories).isSuperset(of: [
                "id", "name", "color_token", "created_at", "updated_at", "created_by",
            ]))
        }
    }

    @Test func localTablesHaveExpectedColumns() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.read { db in
            #expect(try db.columns(in: "settings").map(\.name).contains("value"))
            #expect(try db.columns(in: "sync_state").map(\.name).contains("data"))
            #expect(Set(try db.columns(in: "record_metadata").map(\.name))
                .isSuperset(of: ["record_id", "record_type", "system_fields"]))
            #expect(Set(try db.columns(in: "pending_changes").map(\.name))
                .isSuperset(of: ["record_id", "record_type", "change_kind", "queued_at"]))
        }
    }

    @Test func foreignKeysAreEnforced() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let now = Date()
            let orphan = Container(
                id: AppDatabase.newID(),
                roomId: "NO-SUCH-ROOM",
                name: "Orphan",
                notes: nil,
                labelSlot: nil,
                createdAt: now,
                updatedAt: now,
                createdBy: nil)
            #expect(throws: (any Error).self) {
                try orphan.insert(db)
            }
        }
    }
}
