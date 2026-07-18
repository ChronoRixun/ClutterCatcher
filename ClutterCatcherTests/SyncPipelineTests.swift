import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// The two write paths (plan §3.2):
/// - `performLocalMutation` applies a user change, stamps `updated_at`, and
///   enqueues outbound `pending_changes` rows — all in one transaction.
/// - `applyServerChanges` applies inbound rows verbatim: no restamping, no
///   outbound echo.
@Suite struct SyncPipelineTests {
    private struct Boom: Error {}

    private func pendingRows(_ database: AppDatabase) async throws -> [PendingChange] {
        try await database.writer.read { db in
            try PendingChange.fetchAll(
                db, sql: "SELECT * FROM pending_changes ORDER BY rowid")
        }
    }

    // MARK: Local mutation path

    @Test func mutationSaveStampsUpdatedAtAndEnqueues() async throws {
        let database = try AppDatabase.inMemory()
        let room = try await database.performLocalMutation { mutation in
            var room = Room(
                id: AppDatabase.newID(), name: "Garage", sortOrder: 0, icon: nil,
                createdAt: mutation.now, updatedAt: .distantPast, createdBy: nil)
            try mutation.save(&room)
            return room
        }
        #expect(room.updatedAt > .distantPast, "save must stamp updated_at itself")

        let stored = try await database.writer.read { db in
            try Room.fetchOne(db, key: room.id)
        }
        let storedUpdatedAt = try #require(stored?.updatedAt)
        #expect(abs(storedUpdatedAt.timeIntervalSince(room.updatedAt)) < 0.002)

        let pending = try await pendingRows(database)
        #expect(pending.map(\.recordId) == [room.id])
        #expect(pending.first?.recordType == .room)
        #expect(pending.first?.changeKind == .save)
    }

    @Test func mutationIsOneTransaction() async throws {
        let database = try AppDatabase.inMemory()
        await #expect(throws: Boom.self) {
            try await database.performLocalMutation { mutation in
                var room = Room(
                    id: AppDatabase.newID(), name: "Doomed", sortOrder: 0, icon: nil,
                    createdAt: mutation.now, updatedAt: mutation.now, createdBy: nil)
                try mutation.save(&room)
                throw Boom()
            }
        }
        let (roomCount, pendingCount) = try await database.writer.read { db in
            (try Room.fetchCount(db), try PendingChange.fetchCount(db))
        }
        #expect(roomCount == 0)
        #expect(pendingCount == 0)
    }

    @Test func repositoryWritesEnqueueSaves() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let room = try await rooms.createRoom(name: "Garage", icon: nil)

        var pending = try await pendingRows(database)
        #expect(pending.map(\.recordId) == [room.id])

        var edited = room
        edited.name = "Workshop"
        try await rooms.updateRoom(edited)
        pending = try await pendingRows(database)
        #expect(pending.count == 1, "same record collapses to one pending row")
        #expect(pending.first?.changeKind == .save)
    }

    @Test func roomCascadeDeleteEnqueuesItemsThenContainersThenRoom() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let binA = try await containers.createContainer(roomID: room.id, name: "A", notes: nil)
        let binB = try await containers.createContainer(roomID: room.id, name: "B", notes: nil)
        let item1 = try await items.createItem(
            containerID: binA.id, name: "One", quantity: 1, notes: nil, categoryID: nil)
        let item2 = try await items.createItem(
            containerID: binA.id, name: "Two", quantity: 1, notes: nil, categoryID: nil)
        let item3 = try await items.createItem(
            containerID: binB.id, name: "Three", quantity: 1, notes: nil, categoryID: nil)

        try await rooms.deleteRooms(ids: [room.id])

        let counts = try await database.writer.read { db in
            (try Room.fetchCount(db), try Container.fetchCount(db), try Item.fetchCount(db))
        }
        #expect(counts == (0, 0, 0))

        let pending = try await pendingRows(database)
        #expect(pending.allSatisfy { $0.changeKind == .delete },
                "prior saves must collapse into deletes")
        let kinds = pending.map(\.recordType)
        #expect(kinds == [.item, .item, .item, .container, .container, .room],
                "explicit cascade order is items → containers → rooms")
        #expect(Set(pending.map(\.recordId)) == Set(
            [item1.id, item2.id, item3.id, binA.id, binB.id, room.id]))
    }

    @Test func saveThenDeleteCollapsesToSingleDelete() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let bin = try await containers.createContainer(roomID: room.id, name: "Bin", notes: nil)
        let item = try await items.createItem(
            containerID: bin.id, name: "Wrench", quantity: 1, notes: nil, categoryID: nil)
        try await items.deleteItems(ids: [item.id])

        let pending = try await pendingRows(database)
        let itemRows = pending.filter { $0.recordId == item.id }
        #expect(itemRows.count == 1)
        #expect(itemRows.first?.changeKind == .delete)
    }

    @Test func categoryDeleteReSavesAffectedItems() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)
        let categories = CategoryRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let bin = try await containers.createContainer(roomID: room.id, name: "Bin", notes: nil)
        let category = try await categories.createCategory(name: "Tools", colorToken: "orange")
        let item = try await items.createItem(
            containerID: bin.id, name: "Wrench", quantity: 1, notes: nil, categoryID: category.id)

        try await categories.deleteCategories(ids: [category.id])

        let survivor = try await items.fetchItem(id: item.id)
        #expect(survivor?.categoryId == nil)

        let pending = try await pendingRows(database)
        let itemRow = pending.first { $0.recordId == item.id }
        let categoryRow = pending.first { $0.recordId == category.id }
        #expect(itemRow?.changeKind == .save,
                "the cleared reference must reach the server, not just local FK state")
        #expect(categoryRow?.changeKind == .delete)
    }

    // MARK: Inbound path

    @Test func inboundApplyPreservesServerTimestampsAndEchoesNothing() async throws {
        let database = try AppDatabase.inMemory()
        let serverUpdatedAt = Date(timeIntervalSinceReferenceDate: 777_000_000)
        let room = Room(
            id: AppDatabase.newID(), name: "From Server", sortOrder: 5, icon: nil,
            createdAt: serverUpdatedAt, updatedAt: serverUpdatedAt, createdBy: nil)
        try await database.applyServerChanges { apply in
            try apply.upsert(.room(room))
        }
        let stored = try await database.writer.read { db in
            try Room.fetchOne(db, key: room.id)
        }
        let storedUpdatedAt = try #require(stored?.updatedAt)
        #expect(abs(storedUpdatedAt.timeIntervalSince(serverUpdatedAt)) < 0.002,
                "inbound apply must not restamp server timestamps")
        let pendingCount = try await database.writer.read { db in
            try PendingChange.fetchCount(db)
        }
        #expect(pendingCount == 0, "inbound changes must never echo back out")
    }

    @Test func inboundDeletionCleansRowMetadataAndPending() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let bin = try await containers.createContainer(roomID: room.id, name: "Bin", notes: nil)
        try await database.writer.write { db in
            try RecordMetadata(recordId: room.id, recordType: .room, systemFields: Data([1]))
                .insert(db)
            try RecordMetadata(recordId: bin.id, recordType: .container, systemFields: Data([2]))
                .insert(db)
        }

        let dropped = try await database.applyServerChanges { apply in
            try apply.applyDeletion(type: .room, id: room.id)
        }

        let (roomCount, containerCount, metadataCount, pendingCount) =
            try await database.writer.read { db in
                (try Room.fetchCount(db),
                 try Container.fetchCount(db),
                 try RecordMetadata.fetchCount(db),
                 try PendingChange.fetchCount(db))
            }
        #expect(roomCount == 0)
        #expect(containerCount == 0, "local FK cascade still applies")
        #expect(metadataCount == 0, "metadata for the row and its cascade must go")
        #expect(pendingCount == 0, "pending saves for cascaded rows must go")
        #expect(Set(dropped.map(\.recordId)) == Set([room.id, bin.id]),
                "dropped pending changes are reported for engine-state removal")
    }

    @Test func inboundDeletionOfUnknownRowIsANoOp() async throws {
        let database = try AppDatabase.inMemory()
        let dropped = try await database.applyServerChanges { apply in
            try apply.applyDeletion(type: .item, id: AppDatabase.newID())
        }
        #expect(dropped.isEmpty)
    }

    // MARK: Inbound merge (LWW applied to a real database)

    @Test func applyWithMergeKeepsNewerLocalRowAndRefreshesMetadata() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let room = try await rooms.createRoom(name: "Local Truth", icon: nil)

        var serverRoom = room
        serverRoom.name = "Stale Server"
        serverRoom.updatedAt = Date(timeIntervalSinceReferenceDate: 1)
        let parsed = ParsedServerRecord(row: .room(serverRoom), systemFields: Data([42]))

        let outcome = try await database.applyServerChanges { apply in
            try apply.applyWithMerge(parsed)
        }
        #expect(outcome == .keptLocal)

        let stored = try await database.writer.read { db in
            try Room.fetchOne(db, key: room.id)
        }
        #expect(stored?.name == "Local Truth")
        let metadata = try await database.writer.read { db in
            try RecordMetadata.fetchOne(db, key: room.id)
        }
        #expect(metadata?.systemFields == Data([42]),
                "keep-local must still adopt the server's change tag for the re-send")
        let pendingCount = try await database.writer.read { db in
            try PendingChange.fetchCount(db)
        }
        #expect(pendingCount == 1, "the local save stays queued to overwrite the server")
    }

    @Test func applyWithMergeAcceptsServerWhenLocalUntouched() async throws {
        let database = try AppDatabase.inMemory()
        let room = Room(
            id: AppDatabase.newID(), name: "Original", sortOrder: 0, icon: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0), createdBy: nil)
        try await database.applyServerChanges { apply in
            try apply.upsert(.room(room))
        }

        var serverRoom = room
        serverRoom.name = "Edited Elsewhere"
        serverRoom.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        let parsed = ParsedServerRecord(row: .room(serverRoom), systemFields: Data([7]))
        let outcome = try await database.applyServerChanges { apply in
            try apply.applyWithMerge(parsed)
        }
        #expect(outcome == .applied)
        let stored = try await database.writer.read { db in
            try Room.fetchOne(db, key: room.id)
        }
        #expect(stored?.name == "Edited Elsewhere")
    }

    @Test func applyWithMergeDropsOlderPendingSave() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let room = try await rooms.createRoom(name: "Local Old", icon: nil)

        var serverRoom = room
        serverRoom.name = "Server New"
        serverRoom.updatedAt = Date(timeIntervalSince1970: 4_000_000_000)
        let parsed = ParsedServerRecord(row: .room(serverRoom), systemFields: Data([9]))

        let outcome = try await database.applyServerChanges { apply in
            try apply.applyWithMerge(parsed)
        }
        #expect(outcome == .applied)
        let pendingCount = try await database.writer.read { db in
            try PendingChange.fetchCount(db)
        }
        #expect(pendingCount == 0, "an outdated local save must not re-clobber the server")
    }

    @Test func applyWithMergeReportsOrphanWhenParentMissing() async throws {
        let database = try AppDatabase.inMemory()
        let item = Item(
            id: AppDatabase.newID(), containerId: "NOT-ARRIVED-YET", name: "Early Bird",
            quantity: 1, notes: nil, categoryId: nil, photoAssetRef: nil,
            createdAt: Date(), updatedAt: Date(), createdBy: nil)
        let parsed = ParsedServerRecord(row: .item(item), systemFields: Data([1]))
        let outcome = try await database.applyServerChanges { apply in
            try apply.applyWithMerge(parsed)
        }
        #expect(outcome == .orphaned)
        let (itemCount, metadataCount) = try await database.writer.read { db in
            (try Item.fetchCount(db), try RecordMetadata.fetchCount(db))
        }
        #expect(itemCount == 0)
        #expect(metadataCount == 0, "no ack bookkeeping for a row that was not applied")
    }

    // MARK: Conflict receipts (sync_events)

    @Test func lwwOverwriteRecordsAnActivityEvent() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let room = try await rooms.createRoom(name: "My Offline Edit", icon: nil)

        var serverRoom = room
        serverRoom.name = "Remote Winner"
        serverRoom.updatedAt = Date(timeIntervalSince1970: 4_000_000_000)
        let parsed = ParsedServerRecord(row: .room(serverRoom), systemFields: Data([9]))
        _ = try await database.applyServerChanges { apply in
            try apply.applyWithMerge(parsed)
        }

        let events = try await database.writer.read { db in
            try SyncEvent.fetchAll(db)
        }
        #expect(events.count == 1)
        #expect(events.first?.kind == .localEditOverwritten)
        #expect(events.first?.summary.contains("My Offline Edit") == true,
                "the receipt names the edit the user lost, not the winner")
        #expect(events.first?.recordId == room.id)
    }

    @Test func cleanServerApplyRecordsNoEvent() async throws {
        let database = try AppDatabase.inMemory()
        let room = Room(
            id: AppDatabase.newID(), name: "Untouched", sortOrder: 0, icon: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0), createdBy: nil)
        try await database.applyServerChanges { apply in
            try apply.upsert(.room(room))
        }
        var serverRoom = room
        serverRoom.name = "Routine Update"
        serverRoom.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        let parsed = ParsedServerRecord(row: .room(serverRoom), systemFields: Data([1]))
        _ = try await database.applyServerChanges { apply in
            try apply.applyWithMerge(parsed)
        }
        let eventCount = try await database.writer.read { db in
            try SyncEvent.fetchCount(db)
        }
        #expect(eventCount == 0, "accepting the server without a local edit in flight is not a conflict")
    }

    @Test func keptLocalRecordsNoEventOnRoutineFetch() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let room = try await rooms.createRoom(name: "Local Truth", icon: nil)

        var serverRoom = room
        serverRoom.name = "Stale Server"
        serverRoom.updatedAt = Date(timeIntervalSinceReferenceDate: 1)
        let parsed = ParsedServerRecord(row: .room(serverRoom), systemFields: Data([2]))
        _ = try await database.applyServerChanges { apply in
            try apply.applyWithMerge(parsed)
        }
        let eventCount = try await database.writer.read { db in
            try SyncEvent.fetchCount(db)
        }
        #expect(eventCount == 0,
                "fetch echoes of older server copies happen constantly; only true send-conflicts log a win")
    }

    @Test func overriddenLocalDeleteRecordsAnActivityEvent() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let room = try await rooms.createRoom(name: "Doomed Locally", icon: nil)
        try await rooms.deleteRooms(ids: [room.id])

        var serverRoom = room
        serverRoom.name = "Resurrected Elsewhere"
        serverRoom.updatedAt = Date(timeIntervalSince1970: 4_000_000_000)
        let parsed = ParsedServerRecord(row: .room(serverRoom), systemFields: Data([3]))
        let outcome = try await database.applyServerChanges { apply in
            try apply.applyWithMerge(parsed)
        }
        #expect(outcome == .applied)

        let events = try await database.writer.read { db in
            try SyncEvent.fetchAll(db)
        }
        #expect(events.count == 1)
        #expect(events.first?.kind == .localEditOverwritten)
        #expect(events.first?.summary.contains("Resurrected Elsewhere") == true,
                "no local row survives a delete, so the receipt carries the server's name")
    }

    @Test func remoteDeleteOverUnsentEditRecordsAnActivityEvent() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let room = try await rooms.createRoom(name: "Edited Here", icon: nil)

        _ = try await database.applyServerChanges { apply in
            try apply.applyDeletion(type: .room, id: room.id)
        }

        let events = try await database.writer.read { db in
            try SyncEvent.fetchAll(db)
        }
        #expect(events.count == 1)
        #expect(events.first?.kind == .localEditDroppedByDelete)
        #expect(events.first?.summary.contains("Edited Here") == true)
    }

    @Test func remoteDeleteWithNothingPendingRecordsNoEvent() async throws {
        let database = try AppDatabase.inMemory()
        let room = Room(
            id: AppDatabase.newID(), name: "Fully Synced", sortOrder: 0, icon: nil,
            createdAt: Date(), updatedAt: Date(), createdBy: nil)
        try await database.applyServerChanges { apply in
            try apply.upsert(.room(room))
        }
        _ = try await database.applyServerChanges { apply in
            try apply.applyDeletion(type: .room, id: room.id)
        }
        let eventCount = try await database.writer.read { db in
            try SyncEvent.fetchCount(db)
        }
        #expect(eventCount == 0, "a routine remote delete of a synced row loses nothing")
    }

    // MARK: Seeder + reset through the mutation path

    @Test func seederEnqueuesExactlyWhatItInserts() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()
        let pending = try await pendingRows(database)
        #expect(pending.count == SeedData.rooms.count + SeedData.categories.count)
        #expect(pending.allSatisfy { $0.changeKind == .save })
    }

    @Test func partialSeedRecoveryDoesNotEnqueueSurvivors() async throws {
        let database = try AppDatabase.inMemory()
        let survivor = SeedData.rooms[0]
        try await database.writer.write { db in
            let now = Date()
            try Room(
                id: survivor.id, name: "Owen Renamed This", sortOrder: 0, icon: survivor.icon,
                createdAt: now, updatedAt: now, createdBy: nil
            ).insert(db)
        }
        try Seeder(database: database).seedIfNeeded()

        let renamed = try await database.writer.read { db in
            try Room.fetchOne(db, key: survivor.id)
        }
        #expect(renamed?.name == "Owen Renamed This", "seeder must not overwrite existing rows")
        let pending = try await pendingRows(database)
        #expect(!pending.map(\.recordId).contains(survivor.id),
                "rows the seeder skipped are backfill's job, not the seeder's")
        #expect(pending.count == SeedData.rooms.count - 1 + SeedData.categories.count)
    }

    @Test func resetEnqueuesDeletesForCustomRowsAndSavesForSeeds() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let custom = try await rooms.createRoom(name: "Attic", icon: nil)
        let bin = try await containers.createContainer(
            roomID: SeedData.rooms[0].id, name: "Bin in Seed Room", notes: nil)

        try await SettingsRepository(database: database).resetCatalogAndReseed()

        let pending = try await pendingRows(database)
        let byID = Dictionary(uniqueKeysWithValues: pending.map { ($0.recordId, $0.changeKind) })
        #expect(byID[custom.id] == .delete)
        #expect(byID[bin.id] == .delete)
        for seed in SeedData.rooms {
            #expect(byID[seed.id] == .save, "re-seeded rows overwrite their server records")
        }
        for seed in SeedData.categories {
            #expect(byID[seed.id] == .save)
        }
    }

    // MARK: Backfill

    @Test func backfillEnqueuesExactlyTheUnsyncedRows() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let synced = try await rooms.createRoom(name: "Synced", icon: nil)
        let unsynced = try await rooms.createRoom(name: "Unsynced", icon: nil)
        let bin = try await containers.createContainer(roomID: synced.id, name: "Bin", notes: nil)

        let ghostDeleteID = AppDatabase.newID()
        let ghostQueuedAt = Date(timeIntervalSinceReferenceDate: 500_000_000)
        try await database.writer.write { db in
            // Simulate: `synced` was acked, everything else never uploaded,
            // and one delete is still waiting for a row that no longer exists.
            try PendingChange.deleteAll(db)
            try RecordMetadata(recordId: synced.id, recordType: .room, systemFields: Data([1]))
                .insert(db)
            try PendingChange(
                recordId: ghostDeleteID, recordType: .container,
                changeKind: .delete, queuedAt: ghostQueuedAt
            ).insert(db)
        }

        let enqueued = try await database.writer.write { db in
            try SyncBackfill.enqueueUnsyncedRows(db)
        }
        #expect(enqueued == 2)

        let pending = try await pendingRows(database)
        let byID = Dictionary(uniqueKeysWithValues: pending.map { ($0.recordId, $0.changeKind) })
        #expect(byID[unsynced.id] == .save)
        #expect(byID[bin.id] == .save)
        #expect(byID[synced.id] == nil, "acked rows must not re-upload")
        #expect(byID[ghostDeleteID] == .delete, "backfill must not clobber a queued delete")

        // Idempotent: a second run adds nothing.
        let secondRun = try await database.writer.write { db in
            try SyncBackfill.enqueueUnsyncedRows(db)
        }
        #expect(secondRun == 0)
    }
}
