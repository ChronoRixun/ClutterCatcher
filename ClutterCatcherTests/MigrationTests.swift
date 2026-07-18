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
                let exists = try db.tableExists(table)
                #expect(exists, "missing table \(table)")
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
            let settings = try db.columns(in: "settings").map(\.name)
            #expect(settings.contains("value"))
            let syncState = try db.columns(in: "sync_state").map(\.name)
            #expect(syncState.contains("data"))
            let recordMetadata = Set(try db.columns(in: "record_metadata").map(\.name))
            #expect(recordMetadata.isSuperset(of: ["record_id", "record_type", "system_fields"]))
            let pendingChanges = Set(try db.columns(in: "pending_changes").map(\.name))
            #expect(pendingChanges
                .isSuperset(of: ["record_id", "record_type", "change_kind", "queued_at"]))
        }
    }

    @Test func v2CreatesSyncEventsTable() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.read { db in
            let exists = try db.tableExists("sync_events")
            #expect(exists)
            let columns = Set(try db.columns(in: "sync_events").map(\.name))
            #expect(columns.isSuperset(of: [
                "id", "occurred_at", "kind", "record_type", "record_id", "summary",
            ]))
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
