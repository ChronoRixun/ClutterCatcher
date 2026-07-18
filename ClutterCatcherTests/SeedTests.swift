import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

@Suite struct SeedTests {
    @Test func firstRunSeedsCanonicalCatalog() throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()

        try database.writer.read { db in
            let roomCount = try Room.fetchCount(db)
            #expect(roomCount == SeedData.rooms.count)
            let categoryCount = try Category.fetchCount(db)
            #expect(categoryCount == SeedData.categories.count)
            let seedFlag = try Setting.fetchOne(db, key: Setting.seedAppliedKey)
            #expect(seedFlag != nil)
        }
    }

    @Test func reRunningSeederAddsNothing() throws {
        let database = try AppDatabase.inMemory()
        let seeder = Seeder(database: database)
        try seeder.seedIfNeeded()
        try seeder.seedIfNeeded()

        try database.writer.read { db in
            let roomCount = try Room.fetchCount(db)
            #expect(roomCount == SeedData.rooms.count)
            let categoryCount = try Category.fetchCount(db)
            #expect(categoryCount == SeedData.categories.count)
        }
    }

    @Test func seededRowsUseFixedCompiledInUUIDs() throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()

        try database.writer.read { db in
            for seed in SeedData.rooms {
                let exists = try Room.exists(db, key: seed.id)
                #expect(exists, "missing seed room \(seed.name)")
            }
            for seed in SeedData.categories {
                let exists = try Category.exists(db, key: seed.id)
                #expect(exists, "missing seed category \(seed.name)")
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

    /// Reset wipes user data and lands back on exactly the pristine seed.
    @Test func resetRestoresPristineSeedCatalog() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()

        let customRoomID = AppDatabase.newID()
        try await database.writer.write { db in
            let now = Date()
            try Room(
                id: customRoomID, name: "Attic", sortOrder: 99, icon: "house",
                createdAt: now, updatedAt: now, createdBy: nil
            ).insert(db)
            try Container(
                id: AppDatabase.newID(), roomId: customRoomID, name: "Box",
                notes: nil, labelSlot: nil,
                createdAt: now, updatedAt: now, createdBy: nil
            ).insert(db)
        }

        try await SettingsRepository(database: database).resetCatalogAndReseed()

        try await database.writer.read { db in
            let roomCount = try Room.fetchCount(db)
            #expect(roomCount == SeedData.rooms.count)
            let containerCount = try Container.fetchCount(db)
            #expect(containerCount == 0)
            let categoryCount = try Category.fetchCount(db)
            #expect(categoryCount == SeedData.categories.count)
            let customSurvived = try Room.exists(db, key: customRoomID)
            #expect(!customSurvived)
            let seedFlag = try Setting.fetchOne(db, key: Setting.seedAppliedKey)
            #expect(seedFlag != nil)
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
            let roomCount = try Room.fetchCount(db)
            #expect(roomCount == SeedData.rooms.count)
            let names = try String.fetchAll(
                db, sql: "SELECT name FROM rooms WHERE id = ?", arguments: [survivor.id])
            #expect(names == [survivor.name])
        }
    }
}
