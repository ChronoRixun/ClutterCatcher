import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

@Suite struct SeedTests {
    @Test func firstRunSeedsCanonicalCatalog() throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()

        try database.writer.read { db in
            #expect(try Room.fetchCount(db) == SeedData.rooms.count)
            #expect(try Category.fetchCount(db) == SeedData.categories.count)
            #expect(try Setting.fetchOne(db, key: Setting.seedAppliedKey) != nil)
        }
    }

    @Test func reRunningSeederAddsNothing() throws {
        let database = try AppDatabase.inMemory()
        let seeder = Seeder(database: database)
        try seeder.seedIfNeeded()
        try seeder.seedIfNeeded()

        try database.writer.read { db in
            #expect(try Room.fetchCount(db) == SeedData.rooms.count)
            #expect(try Category.fetchCount(db) == SeedData.categories.count)
        }
    }

    @Test func seededRowsUseFixedCompiledInUUIDs() throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()

        try database.writer.read { db in
            for seed in SeedData.rooms {
                #expect(try Room.exists(db, key: seed.id), "missing seed room \(seed.name)")
            }
            for seed in SeedData.categories {
                #expect(try Category.exists(db, key: seed.id), "missing seed category \(seed.name)")
            }
        }
    }

    @Test func seedIDsAreWellFormedAndUnique() {
        let allIDs = SeedData.rooms.map(\.id) + SeedData.categories.map(\.id)
        #expect(Set(allIDs).count == allIDs.count)
        for id in allIDs {
            #expect(UUID(uuidString: id) != nil, "malformed seed id \(id)")
            #expect(id == id.uppercased(), "seed id not uppercase: \(id)")
        }
    }

    /// A partial seed (rows in, flag never written — e.g. old crash) must
    /// recover on the next run without duplicating anything.
    @Test func partialSeedRecoversWithoutDuplicates() throws {
        let database = try AppDatabase.inMemory()
        let survivor = SeedData.rooms[0]
        try database.writer.write { db in
            let now = Date()
            try Room(
                id: survivor.id,
                name: survivor.name,
                sortOrder: 0,
                icon: survivor.icon,
                createdAt: now,
                updatedAt: now,
                createdBy: nil
            ).insert(db)
        }

        try Seeder(database: database).seedIfNeeded()

        try database.writer.read { db in
            #expect(try Room.fetchCount(db) == SeedData.rooms.count)
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM rooms WHERE id = ?", arguments: [survivor.id])
            #expect(names == [survivor.name])
        }
    }
}
