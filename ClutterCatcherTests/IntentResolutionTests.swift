import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// M7b (U9): the Find Item intent's pure half — name resolution ranking
/// (exact → prefix → substring), entity lookup by id, the spoken location
/// phrase, and the U11 read-only receipt.
@Suite struct IntentResolutionTests {
    private struct Fixture {
        var database: AppDatabase
        var holidayBins: Container
        var lights: Item
        var plainLights: Item
    }

    private func makeFixture() async throws -> Fixture {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let items = ItemRepository(database: database)
        let garage = try await rooms.createRoom(name: "Garage", icon: nil)
        let holidayBins = try await containers.createContainer(
            roomID: garage.id, name: "Holiday Bins", notes: nil)
        let lights = try await items.createItem(
            containerID: holidayBins.id, name: "Christmas Lights", quantity: 1,
            notes: nil, categoryID: nil)
        let plainLights = try await items.createItem(
            containerID: holidayBins.id, name: "Lights", quantity: 1,
            notes: nil, categoryID: nil)
        _ = try await items.createItem(
            containerID: holidayBins.id, name: "Wreath", quantity: 1,
            notes: nil, categoryID: nil)
        return Fixture(
            database: database, holidayBins: holidayBins,
            lights: lights, plainLights: plainLights)
    }

    @Test func exactMatchRanksAheadOfSubstringMatches() async throws {
        let fixture = try await makeFixture()
        let matches = try await fixture.database.writer.read { db in
            try ItemIntentResolution.matches(db, query: "lights")
        }
        #expect(matches.map(\.name) == ["Lights", "Christmas Lights"],
            "exact (case-insensitive) first, then the substring hit")
    }

    @Test func partialMatchesResolveAlphabetically() async throws {
        let fixture = try await makeFixture()
        let matches = try await fixture.database.writer.read { db in
            try ItemIntentResolution.matches(db, query: "christ")
        }
        #expect(matches.map(\.name) == ["Christmas Lights"])
    }

    @Test func noMatchResolvesToNothing() async throws {
        let fixture = try await makeFixture()
        let matches = try await fixture.database.writer.read { db in
            try ItemIntentResolution.matches(db, query: "snowblower")
        }
        #expect(matches.isEmpty, "Siri asks again rather than guessing")
        let blank = try await fixture.database.writer.read { db in
            try ItemIntentResolution.matches(db, query: "   ")
        }
        #expect(blank.isEmpty)
    }

    @Test func likeWildcardsInSpokenTextMatchLiterally() async throws {
        let fixture = try await makeFixture()
        let matches = try await fixture.database.writer.read { db in
            try ItemIntentResolution.matches(db, query: "%")
        }
        #expect(matches.isEmpty, "a literal % is a name character, not a wildcard")
    }

    @Test func entityLookupByIdentifierResolves() async throws {
        let fixture = try await makeFixture()
        let matches = try await fixture.database.writer.read {
            [id = fixture.lights.id] db in
            try ItemIntentResolution.entities(db, identifiers: [id])
        }
        #expect(matches.map(\.name) == ["Christmas Lights"])
        #expect(matches.first?.containerID == fixture.holidayBins.id)
    }

    @Test func locationPhraseReadsHouseholdEnglish() async throws {
        let fixture = try await makeFixture()
        let match = try await fixture.database.writer.read {
            [id = fixture.lights.id] db in
            try ItemIntentResolution.entities(db, identifiers: [id]).first
        }
        #expect(try #require(match).locationPhrase
            == "Holiday Bins in the Garage — 3 items")
    }

    @Test func possessiveRoomNamesDropTheArticle() async throws {
        let database = try AppDatabase.inMemory()
        let closet = try await RoomRepository(database: database)
            .createRoom(name: "Andrew's Closet", icon: nil)
        let shelf = try await ContainerRepository(database: database)
            .createContainer(roomID: closet.id, name: "Top Shelf", notes: nil)
        let item = try await ItemRepository(database: database).createItem(
            containerID: shelf.id, name: "Board Games", quantity: 1,
            notes: nil, categoryID: nil)
        let match = try await database.writer.read { [id = item.id] db in
            try ItemIntentResolution.entities(db, identifiers: [id]).first
        }
        #expect(try #require(match).locationPhrase
            == "Top Shelf in Andrew's Closet — 1 item",
            "\"in the Andrew's Closet\" isn't household English")
    }

    // U11: intents are read-only — no writes from resolution, ever.
    @Test func resolutionWritesNothingToTheSyncQueue() async throws {
        let fixture = try await makeFixture()
        let before = try await queueCounts(fixture.database)
        _ = try await fixture.database.writer.read { db in
            try ItemIntentResolution.matches(db, query: "lights")
        }
        _ = try await fixture.database.writer.read { db in
            try ItemIntentResolution.all(db)
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
