import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// M7b (U13): the category-browse grouping query — items grouped
/// room → container in catalog order — plus the U11 receipt that browsing
/// is a pure read.
@Suite struct CategoryBrowseTests {
    private struct Fixture {
        var database: AppDatabase
        // Module-qualified: objc/runtime.h also vends a `Category` typedef.
        var seasonal: ClutterCatcher.Category
        var garage: Room
        var basement: Room
        var holidayBins: Container
        var campingTub: Container
        var archiveBox: Container
    }

    /// Garage is created first (sort_order 0), Basement second — so catalog
    /// order disagrees with alphabetical order and the test can tell them
    /// apart.
    private func makeFixture() async throws -> Fixture {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)
        let categories = CategoryRepository(database: database)

        let garage = try await rooms.createRoom(name: "Garage", icon: nil)
        let basement = try await rooms.createRoom(name: "Basement", icon: nil)
        let holidayBins = try await containers.createContainer(
            roomID: garage.id, name: "Holiday Bins", notes: nil)
        let campingTub = try await containers.createContainer(
            roomID: garage.id, name: "Camping Tub", notes: nil)
        let archiveBox = try await containers.createContainer(
            roomID: basement.id, name: "Archive Box", notes: nil)
        let seasonal = try await categories.createCategory(name: "Seasonal", colorToken: "red")

        _ = try await items.createItem(
            containerID: holidayBins.id, name: "Wreath", quantity: 1,
            notes: nil, categoryID: seasonal.id)
        _ = try await items.createItem(
            containerID: holidayBins.id, name: "Christmas Lights", quantity: 3,
            notes: nil, categoryID: seasonal.id)
        _ = try await items.createItem(
            containerID: campingTub.id, name: "Beach Umbrella", quantity: 1,
            notes: nil, categoryID: seasonal.id)
        _ = try await items.createItem(
            containerID: archiveBox.id, name: "Advent Calendar", quantity: 1,
            notes: nil, categoryID: seasonal.id)
        // Not Seasonal — must never appear in the browse.
        _ = try await items.createItem(
            containerID: holidayBins.id, name: "Extension Cord", quantity: 1,
            notes: nil, categoryID: nil)
        return Fixture(
            database: database, seasonal: seasonal, garage: garage, basement: basement,
            holidayBins: holidayBins, campingTub: campingTub, archiveBox: archiveBox)
    }

    @Test func browseGroupsRoomThenContainerInCatalogOrder() async throws {
        let fixture = try await makeFixture()
        let browse = try await fixture.database.writer.read { db in
            try CategoryRepository.fetchBrowse(db, categoryID: fixture.seasonal.id)
        }
        let unwrapped = try #require(browse)
        #expect(unwrapped.itemCount == 4)
        // Rooms follow sort_order — Garage before Basement despite the
        // alphabet; containers and items sort by name within their parent.
        #expect(unwrapped.rooms.map(\.name) == ["Garage", "Basement"])
        #expect(unwrapped.rooms[0].containers.map(\.name) == ["Camping Tub", "Holiday Bins"])
        #expect(unwrapped.rooms[0].containers[1].items.map(\.name)
            == ["Christmas Lights", "Wreath"])
        #expect(unwrapped.rooms[1].containers.map(\.name) == ["Archive Box"])
        #expect(unwrapped.rooms[1].containers[0].items.map(\.name) == ["Advent Calendar"])
    }

    @Test func browseExcludesOtherCategoriesAndTheUncategorized() async throws {
        let fixture = try await makeFixture()
        let browse = try await fixture.database.writer.read { db in
            try CategoryRepository.fetchBrowse(db, categoryID: fixture.seasonal.id)
        }
        let names = try #require(browse).rooms
            .flatMap(\.containers).flatMap(\.items).map(\.name)
        #expect(!names.contains("Extension Cord"))
    }

    @Test func emptyCategoryBrowsesToNoGroups() async throws {
        let database = try AppDatabase.inMemory()
        let empty = try await CategoryRepository(database: database)
            .createCategory(name: "Keepsakes", colorToken: "purple")
        let browse = try await database.writer.read { db in
            try CategoryRepository.fetchBrowse(db, categoryID: empty.id)
        }
        let unwrapped = try #require(browse)
        #expect(unwrapped.rooms.isEmpty)
        #expect(unwrapped.itemCount == 0)
        #expect(unwrapped.category.name == "Keepsakes")
    }

    @Test func missingCategoryBrowsesToNil() async throws {
        let database = try AppDatabase.inMemory()
        let browse = try await database.writer.read { db in
            try CategoryRepository.fetchBrowse(db, categoryID: "NOT-A-CATEGORY")
        }
        #expect(browse == nil)
    }

    // U11: browsing is a read — the outbound queue and the activity log
    // must not move.
    @Test func browsingWritesNothingToTheSyncQueue() async throws {
        let fixture = try await makeFixture()
        let before = try await queueCounts(fixture.database)
        _ = try await fixture.database.writer.read { db in
            try CategoryRepository.fetchBrowse(db, categoryID: fixture.seasonal.id)
        }
        let after = try await queueCounts(fixture.database)
        #expect(after == before)
    }

    private func queueCounts(_ database: AppDatabase) async throws -> [Int] {
        try await database.writer.read { db in
            [try PendingChange.fetchCount(db),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_events") ?? 0]
        }
    }
}
