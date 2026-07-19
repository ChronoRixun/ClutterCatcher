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
                "id", "room_id", "name", "notes", "label_slot", "cover_item_id",
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

    @Test func v3CreatesParticipantsAndOrphanedRecordsTables() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.read { db in
            let participants = Set(try db.columns(in: "participants").map(\.name))
            #expect(participants.isSuperset(of: ["user_record_name", "display_name"]))
            let orphans = Set(try db.columns(in: "orphaned_records").map(\.name))
            #expect(orphans.isSuperset(of: [
                "record_id", "record_type", "payload", "system_fields", "buffered_at",
            ]))
        }
    }

    /// M6 migration v4 (P10): additive `cover_item_id` on `containers`, no
    /// backfill — a row that existed before v4 keeps NULL — and v1–v3 still
    /// apply in order. Driven through a partial migration so the "existing
    /// row" is genuinely pre-v4.
    @Test func v4AddsCoverItemIdAdditivelyWithoutBackfill() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = AppDatabase.migrator
        try migrator.migrate(dbQueue, upTo: "v3")

        let roomID = AppDatabase.newID()
        let containerID = AppDatabase.newID()
        let now = Date()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO rooms (id, name, sort_order, created_at, updated_at)
                    VALUES (?, 'Garage', 0, ?, ?)
                    """,
                arguments: [roomID, now, now])
            try db.execute(
                sql: """
                    INSERT INTO containers (id, room_id, name, created_at, updated_at)
                    VALUES (?, ?, 'Bin', ?, ?)
                    """,
                arguments: [containerID, roomID, now, now])
        }

        // Column absent before v4.
        let hadColumnBefore = try dbQueue.read { db in
            try db.columns(in: "containers").map(\.name).contains("cover_item_id")
        }
        #expect(!hadColumnBefore)

        try migrator.migrate(dbQueue) // apply v4

        let cover = try dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT cover_item_id FROM containers WHERE id = ?",
                arguments: [containerID])
        }
        #expect(cover == nil, "existing rows get cover_item_id = NULL (no backfill)")

        // v2/v3 tables survive the full run — v4 didn't disturb the order.
        let (hasEvents, hasOrphans, hasColumnNow) = try dbQueue.read { db in
            (try db.tableExists("sync_events"),
             try db.tableExists("orphaned_records"),
             try db.columns(in: "containers").map(\.name).contains("cover_item_id"))
        }
        #expect(hasEvents)
        #expect(hasOrphans)
        #expect(hasColumnNow)
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
                coverItemId: nil,
                createdAt: now,
                updatedAt: now,
                createdBy: nil)
            #expect(throws: (any Error).self) {
                try orphan.insert(db)
            }
        }
    }
}
