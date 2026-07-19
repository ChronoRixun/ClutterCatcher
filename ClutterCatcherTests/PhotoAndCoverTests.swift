import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// M6 cover (P4/P10/P11) and photo LWW (P6). Cover is a soft container→item
/// pointer resolved to the item's `photo_asset_ref` at display time, with
/// graceful fallback; the photo id is an ordinary synced field, so LWW governs
/// a photo replacement exactly like any other edit.
@Suite struct PhotoAndCoverTests {
    private struct ObservationEndedWithoutValue: Error {}

    private func firstValue<T: Sendable>(
        of observation: AsyncValueObservation<T>
    ) async throws -> T {
        for try await value in observation {
            return value
        }
        throw ObservationEndedWithoutValue()
    }

    private let stamp = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Cover resolution

    @Test func coverResolvesToTheItemsPhotoRef() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let container = try await containers.createContainer(roomID: room.id, name: "Bin", notes: nil)
        let item = try await items.createItem(
            containerID: container.id, name: "Drill",
            quantity: 1, notes: nil, categoryID: nil, photoAssetRef: "REF-COVER")
        try await containers.setCover(containerID: container.id, itemID: item.id)

        let entries = try await firstValue(of: containers.observeContainers(inRoom: room.id))
        #expect(entries.count == 1)
        #expect(entries.first?.container.coverItemId == item.id)
        #expect(entries.first?.coverPhotoAssetRef == "REF-COVER",
                "the list resolves the cover item's photo id")
    }

    @Test func deletingCoverItemFallsBackAndClearsPointer() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let container = try await containers.createContainer(roomID: room.id, name: "Bin", notes: nil)
        let item = try await items.createItem(
            containerID: container.id, name: "Drill",
            quantity: 1, notes: nil, categoryID: nil, photoAssetRef: "REF-COVER")
        try await containers.setCover(containerID: container.id, itemID: item.id)

        try await items.deleteItems(ids: [item.id])

        let entries = try await firstValue(of: containers.observeContainers(inRoom: room.id))
        #expect(entries.count == 1,
                "the container survives its cover item's deletion (soft ref, no cascade)")
        #expect(entries.first?.coverPhotoAssetRef == nil, "cover falls back gracefully (P10)")
        #expect(entries.first?.container.coverItemId == nil,
                "P11 tracked re-save cleared the stale pointer")
    }

    @Test func setCoverThenClearRoundTrips() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let container = try await containers.createContainer(roomID: room.id, name: "Bin", notes: nil)
        let item = try await items.createItem(
            containerID: container.id, name: "Drill",
            quantity: 1, notes: nil, categoryID: nil, photoAssetRef: "REF-COVER")

        try await containers.setCover(containerID: container.id, itemID: item.id)
        var stored = try await containers.fetchContainer(id: container.id)
        #expect(stored?.coverItemId == item.id)

        try await containers.setCover(containerID: container.id, itemID: nil)
        stored = try await containers.fetchContainer(id: container.id)
        #expect(stored?.coverItemId == nil)
    }

    // MARK: Photo LWW (P6)

    /// A peer replacing the photo (a newer record with a fresh id) is accepted
    /// when there's no local edit — seeded through the server path so no
    /// pending change exists (LWW `acceptServer`).
    @Test func newerServerPhotoReplaceIsAccepted() async throws {
        let database = try AppDatabase.inMemory()
        let later = stamp.addingTimeInterval(100)
        let roomID = AppDatabase.newID()
        let containerID = AppDatabase.newID()
        let itemID = AppDatabase.newID()

        try await database.applyServerChanges { [stamp] apply in
            try apply.upsert(.room(Room(
                id: roomID, name: "Garage", sortOrder: 0, icon: nil,
                createdAt: stamp, updatedAt: stamp, createdBy: nil)))
            try apply.upsert(.container(Container(
                id: containerID, roomId: roomID, name: "Bin", notes: nil,
                labelSlot: nil, coverItemId: nil,
                createdAt: stamp, updatedAt: stamp, createdBy: nil)))
            try apply.upsert(.item(Item(
                id: itemID, containerId: containerID, name: "Drill", quantity: 1,
                notes: nil, categoryId: nil, photoAssetRef: "REF-OLD",
                createdAt: stamp, updatedAt: stamp, createdBy: nil)))
        }

        let replaced = ParsedServerRecord(
            row: .item(Item(
                id: itemID, containerId: containerID, name: "Drill", quantity: 1,
                notes: nil, categoryId: nil, photoAssetRef: "REF-NEW",
                createdAt: stamp, updatedAt: later, createdBy: nil)),
            systemFields: Data([1]))
        let outcome = try await database.applyServerChanges { apply in
            try apply.applyWithMerge(replaced)
        }
        #expect(outcome == .applied)

        let stored = try await database.writer.read { db in try Item.fetchOne(db, key: itemID) }
        #expect(stored?.photoAssetRef == "REF-NEW", "a newer photo-id change wins (P6/LWW)")
    }

    /// A local photo change in flight (pending save) beats an older inbound
    /// record — the household converges on the latest photo.
    @Test func olderServerPhotoLosesToPendingLocalPhoto() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)

        let room = try await rooms.createRoom(name: "Garage", icon: nil)
        let container = try await containers.createContainer(roomID: room.id, name: "Bin", notes: nil)
        let item = try await items.createItem(
            containerID: container.id, name: "Drill",
            quantity: 1, notes: nil, categoryID: nil, photoAssetRef: "REF-LOCAL")

        let stale = ParsedServerRecord(
            row: .item(Item(
                id: item.id, containerId: container.id, name: "Drill", quantity: 1,
                notes: nil, categoryId: nil, photoAssetRef: "REF-STALE",
                createdAt: item.createdAt, updatedAt: Date(timeIntervalSince1970: 0),
                createdBy: nil)),
            systemFields: Data([2]))
        let outcome = try await database.applyServerChanges { apply in
            try apply.applyWithMerge(stale)
        }
        #expect(outcome == .keptLocal)

        let stored = try await database.writer.read { db in try Item.fetchOne(db, key: item.id) }
        #expect(stored?.photoAssetRef == "REF-LOCAL", "the newer local photo is kept")
    }
}
