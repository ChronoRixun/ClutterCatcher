import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

@Suite struct RepositoryTests {
    // MARK: Helpers

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    private struct ObservationEndedWithoutValue: Error {}

    /// The first value of an observation — a plain fetch through the same
    /// code path the UI uses.
    private func firstValue<T: Sendable>(
        of observation: AsyncValueObservation<T>
    ) async throws -> T {
        for try await value in observation {
            return value
        }
        throw ObservationEndedWithoutValue()
    }

    // MARK: Rooms

    @Test func roomCreateAssignsSequentialSortOrder() async throws {
        let database = try makeDatabase()
        let rooms = RoomRepository(database: database)
        let first = try await rooms.createRoom(name: "  Garage  ", icon: "car")
        let second = try await rooms.createRoom(name: "Attic", icon: nil)
        #expect(first.name == "Garage", "repositories own name trimming")
        #expect(first.sortOrder == 0)
        #expect(second.sortOrder == 1)
        #expect(UUID(uuidString: first.id) != nil)
    }

    @Test func roomUpdateRenamesAndBumpsTimestamp() async throws {
        let database = try makeDatabase()
        let rooms = RoomRepository(database: database)
        let created = try await rooms.createRoom(name: "Garage", icon: "car")
        // Outlast both the Date resolution and GRDB's millisecond storage
        // truncation, so a strict > proves the update actually re-stamped.
        try await Task.sleep(for: .milliseconds(20))
        var edited = created
        edited.name = "Workshop"
        try await rooms.updateRoom(edited)
        let fetched = try await rooms.allRooms()
        #expect(fetched.map(\.name) == ["Workshop"])
        #expect(fetched[0].updatedAt > created.updatedAt)
    }

    @Test func roomReorderPersistsNewOrder() async throws {
        let database = try makeDatabase()
        let rooms = RoomRepository(database: database)
        let a = try await rooms.createRoom(name: "A", icon: nil)
        let b = try await rooms.createRoom(name: "B", icon: nil)
        let c = try await rooms.createRoom(name: "C", icon: nil)
        try await rooms.reorderRooms(orderedIDs: [c.id, a.id, b.id])
        let ordered = try await rooms.allRooms()
        #expect(ordered.map(\.name) == ["C", "A", "B"])
    }

    @Test func roomListCountsContainers() async throws {
        let database = try makeDatabase()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        try await containers.createContainer(roomID: room.id, name: "Bin 1", notes: nil)
        try await containers.createContainer(roomID: room.id, name: "Bin 2", notes: nil)
        let list = try await firstValue(of: rooms.observeRoomList())
        #expect(list.count == 1)
        #expect(list[0].containerCount == 2)
    }

    // MARK: Cascades

    @Test func deletingRoomCascadesToContainersAndItems() async throws {
        let database = try makeDatabase()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let container = try await containers.createContainer(
            roomID: room.id, name: "Tool Bin", notes: nil)
        try await items.createItem(
            containerID: container.id, name: "Wrench",
            quantity: 1, notes: nil, categoryID: nil)

        try await rooms.deleteRooms(ids: [room.id])

        let (roomCount, containerCount, itemCount) = try await database.writer.read { db in
            (try Room.fetchCount(db), try Container.fetchCount(db), try Item.fetchCount(db))
        }
        #expect(roomCount == 0)
        #expect(containerCount == 0)
        #expect(itemCount == 0)
    }

    @Test func deletingCategoryNullsItemCategory() async throws {
        let database = try makeDatabase()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)
        let categories = CategoryRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let container = try await containers.createContainer(
            roomID: room.id, name: "Tool Bin", notes: nil)
        let category = try await categories.createCategory(name: "Tools", colorToken: "orange")
        let item = try await items.createItem(
            containerID: container.id, name: "Wrench",
            quantity: 1, notes: nil, categoryID: category.id)

        try await categories.deleteCategories(ids: [category.id])

        let survivor = try await items.fetchItem(id: item.id)
        #expect(survivor != nil)
        #expect(survivor?.categoryId == nil)
    }

    // MARK: Container detail

    @Test func containerDetailJoinsRoomAndCategories() async throws {
        let database = try makeDatabase()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)
        let categories = CategoryRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let container = try await containers.createContainer(
            roomID: room.id, name: "Tool Bin", notes: "  top shelf  ")
        let category = try await categories.createCategory(name: "Tools", colorToken: "orange")
        try await items.createItem(
            containerID: container.id, name: "Wrench",
            quantity: 3, notes: nil, categoryID: category.id)

        let detail = try await firstValue(
            of: containers.observeDetail(containerID: container.id))
        #expect(detail?.roomName == "Garage")
        #expect(detail?.container.notes == "top shelf")
        #expect(detail?.items.count == 1)
        #expect(detail?.items[0].categoryName == "Tools")
        #expect(detail?.items[0].item.quantity == 3)

        let missing = try await firstValue(
            of: containers.observeDetail(containerID: "NOT-A-REAL-ID"))
        #expect(missing == nil)
    }

    // MARK: Label slots

    @Test func labelSlotsAreSequentialAndStable() async throws {
        let database = try makeDatabase()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let a = try await containers.createContainer(roomID: room.id, name: "A", notes: nil)
        let b = try await containers.createContainer(roomID: room.id, name: "B", notes: nil)
        let c = try await containers.createContainer(roomID: room.id, name: "C", notes: nil)

        let firstBatch = try await containers.assignLabelSlots(containerIDs: [a.id, b.id])
        #expect(firstBatch[a.id] == 1)
        #expect(firstBatch[b.id] == 2)

        // Re-printing A must keep its slot; C continues the sequence.
        let secondBatch = try await containers.assignLabelSlots(containerIDs: [a.id, c.id])
        #expect(secondBatch[a.id] == 1)
        #expect(secondBatch[c.id] == 3)
    }

    // MARK: Search

    @Test func searchMatchesAcrossEntitiesWithContext() async throws {
        let database = try makeDatabase()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)
        let search = SearchRepository(database: database)

        let garage = try await rooms.createRoom(name: "Garage", icon: nil)
        let bin = try await containers.createContainer(
            roomID: garage.id, name: "Holiday Bin", notes: nil)
        try await items.createItem(
            containerID: bin.id, name: "Christmas lights",
            quantity: 4, notes: nil, categoryID: nil)

        let results = try await firstValue(of: search.observeResults(matching: "christmas"))
        #expect(results.rooms.isEmpty)
        #expect(results.items.count == 1)
        #expect(results.items[0].containerName == "Holiday Bin")
        #expect(results.items[0].roomName == "Garage")

        let containerHits = try await firstValue(of: search.observeResults(matching: "holiday"))
        #expect(containerHits.containers.count == 1)
    }

    @Test func searchEscapesLikeWildcards() async throws {
        let database = try makeDatabase()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)
        let search = SearchRepository(database: database)

        let room = try await rooms.createRoom(name: "Closet", icon: nil)
        let bin = try await containers.createContainer(roomID: room.id, name: "Fabric", notes: nil)
        try await items.createItem(
            containerID: bin.id, name: "100% cotton sheets",
            quantity: 1, notes: nil, categoryID: nil)
        try await items.createItem(
            containerID: bin.id, name: "cotton socks",
            quantity: 1, notes: nil, categoryID: nil)

        let literal = try await firstValue(of: search.observeResults(matching: "100%"))
        #expect(literal.items.map(\.item.name) == ["100% cotton sheets"])
    }
}
