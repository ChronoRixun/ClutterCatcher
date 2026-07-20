import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// M7b (U8): the pure half of Core Spotlight indexing — payload building,
/// thumbnail resolution, and the diff that prunes deletions and follows the
/// reset/join wipes. Nothing here touches CSSearchableIndex: the actor is a
/// thin batched writer over exactly these seams.
@Suite struct SpotlightIndexTests {
    private struct Fixture {
        var database: AppDatabase
        var garage: Room
        var holidayBins: Container
        var lights: Item
        // Module-qualified: objc/runtime.h also vends a `Category` typedef.
        var seasonal: ClutterCatcher.Category
    }

    private func makeFixture() async throws -> Fixture {
        let database = try AppDatabase.inMemory()
        let garage = try await RoomRepository(database: database)
            .createRoom(name: "Garage", icon: nil)
        let holidayBins = try await ContainerRepository(database: database)
            .createContainer(roomID: garage.id, name: "Holiday Bins", notes: nil)
        let seasonal = try await CategoryRepository(database: database)
            .createCategory(name: "Seasonal", colorToken: "red")
        let lights = try await ItemRepository(database: database).createItem(
            containerID: holidayBins.id, name: "Christmas Lights", quantity: 3,
            notes: nil, categoryID: seasonal.id, photoAssetRef: "PHOTO-REF-1")
        return Fixture(
            database: database, garage: garage, holidayBins: holidayBins,
            lights: lights, seasonal: seasonal)
    }

    private func entries(_ database: AppDatabase) async throws -> [SpotlightEntry] {
        try await database.writer.read { db in
            try SpotlightCatalog.entries(db)
        }
    }

    // MARK: Payload building

    @Test func containerEntryCarriesNameRoomAndIdentifierURL() async throws {
        let fixture = try await makeFixture()
        let all = try await entries(fixture.database)
        let entry = try #require(all.first {
            $0.domain == .container
                && $0.identifier.contains(fixture.holidayBins.id)
        })
        #expect(entry.title == "Holiday Bins")
        #expect(entry.contentDescription == "Garage")
        #expect(entry.keywords == ["Garage"])
        #expect(entry.identifier == "cluttercatcher://c/\(fixture.holidayBins.id)")
        #expect(entry.thumbnailRef == nil, "no cover designated, no thumbnail")
    }

    @Test func itemEntryCarriesPathCategoryAndHighlightIdentifier() async throws {
        let fixture = try await makeFixture()
        let all = try await entries(fixture.database)
        let entry = try #require(all.first { $0.domain == .item })
        #expect(entry.title == "Christmas Lights")
        #expect(entry.contentDescription == "Garage → Holiday Bins")
        #expect(entry.keywords == ["Holiday Bins", "Garage", "Seasonal"])
        #expect(entry.thumbnailRef == "PHOTO-REF-1")
        // The identifier IS the deep link: tapping the result rides the
        // existing URL vocabulary straight into U14's highlight route.
        let url = try #require(URL(string: entry.identifier))
        #expect(Route(deepLink: url) == .container(
            id: fixture.holidayBins.id, highlightItemID: fixture.lights.id))
    }

    @Test func containerCoverResolvesAsItsThumbnailRef() async throws {
        let fixture = try await makeFixture()
        try await ContainerRepository(database: fixture.database)
            .setCover(containerID: fixture.holidayBins.id, itemID: fixture.lights.id)
        let all = try await entries(fixture.database)
        let entry = try #require(all.first { $0.domain == .container })
        #expect(entry.thumbnailRef == "PHOTO-REF-1")
    }

    @Test func thumbnailURLResolvesOnlyWhenTheFileIsCached() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SpotlightThumbTest-\(UUID().uuidString)")
        let store = PhotoStore(root: root)
        let entry = SpotlightEntry(
            identifier: "cluttercatcher://c/X?item=Y", domain: .item,
            title: "Lights", contentDescription: "Garage → Bins",
            keywords: [], thumbnailRef: "REF-1")
        #expect(SpotlightIndexer.thumbnailURL(for: entry, photoStore: store) == nil,
            "a referenced photo whose bytes aren't cached is a text-only result (P13)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("thumb".utf8).write(to: store.thumbnailURL(for: "REF-1"))
        #expect(SpotlightIndexer.thumbnailURL(for: entry, photoStore: store)
            == store.thumbnailURL(for: "REF-1"))
        var noRef = entry
        noRef.thumbnailRef = nil
        #expect(SpotlightIndexer.thumbnailURL(for: noRef, photoStore: store) == nil)
    }

    // MARK: Diff — prune and rebuild at the seam

    @Test func deletingAnItemPrunesExactlyItsEntry() async throws {
        let fixture = try await makeFixture()
        let before = try await entries(fixture.database)
        try await ItemRepository(database: fixture.database)
            .deleteItems(ids: [fixture.lights.id])
        let after = try await entries(fixture.database)
        let changes = SpotlightDiff.changes(from: keyed(before), to: after)
        #expect(changes.deletedIdentifiers == [
            SpotlightCatalog.itemIdentifier(
                containerID: fixture.holidayBins.id, itemID: fixture.lights.id),
        ])
        #expect(changes.upserts.isEmpty,
            "the container entry didn't change; nothing re-indexes")
    }

    @Test func renamingAnItemReindexesOnlyThatEntry() async throws {
        let fixture = try await makeFixture()
        let before = try await entries(fixture.database)
        var renamed = fixture.lights
        renamed.name = "Fairy Lights"
        try await ItemRepository(database: fixture.database).updateItem(renamed)
        let after = try await entries(fixture.database)
        let changes = SpotlightDiff.changes(from: keyed(before), to: after)
        #expect(changes.upserts.map(\.title) == ["Fairy Lights"])
        #expect(changes.deletedIdentifiers.isEmpty)
    }

    @Test func catalogResetClearsEveryEntry() async throws {
        let fixture = try await makeFixture()
        let before = try await entries(fixture.database)
        #expect(!before.isEmpty)
        try await SettingsRepository(database: fixture.database).resetCatalogAndReseed()
        let after = try await entries(fixture.database)
        #expect(after.isEmpty, "the starter seed has no containers or items")
        let changes = SpotlightDiff.changes(from: keyed(before), to: after)
        #expect(Set(changes.deletedIdentifiers) == Set(before.map(\.identifier)))
    }

    @Test func householdJoinWipeClearsEveryEntry() async throws {
        let fixture = try await makeFixture()
        let before = try await entries(fixture.database)
        try await fixture.database.writer.write { db in
            try ParticipantBootstrap.wipeAndAdopt(
                db, zoneOwnerName: "OWNER", roster: [])
        }
        let after = try await entries(fixture.database)
        #expect(after.isEmpty)
        let changes = SpotlightDiff.changes(from: keyed(before), to: after)
        #expect(Set(changes.deletedIdentifiers) == Set(before.map(\.identifier)))
    }

    // U11: the index is derived state — building it moves neither the
    // outbound queue nor the activity log.
    @Test func indexSnapshotsWriteNothingToTheSyncQueue() async throws {
        let fixture = try await makeFixture()
        let before = try await queueCounts(fixture.database)
        let snapshot = try await entries(fixture.database)
        _ = SpotlightDiff.changes(from: [:], to: snapshot)
        let after = try await queueCounts(fixture.database)
        #expect(after == before)
    }

    // MARK: Helpers

    private func keyed(_ entries: [SpotlightEntry]) -> [String: SpotlightEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.identifier, $0) })
    }

    private func queueCounts(_ database: AppDatabase) async throws -> [Int] {
        try await database.writer.read { db in
            [try PendingChange.fetchCount(db),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_events") ?? 0]
        }
    }
}
