import CloudKit
import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// M3-B/E/F: the share-acceptance decision table, the wipe-and-adopt
/// transaction behind joining, created_by resolution, and the owner-only
/// reset ruling.
@Suite struct AcceptanceFlowTests {
    // MARK: Decision table (fresh / pristine seed / user data)

    @Test func freshInstallProceedsWithoutConfirmation() async throws {
        let database = try AppDatabase.inMemory()
        let disposition = try await database.writer.read { db in
            try AcceptanceGuard.disposition(db)
        }
        #expect(disposition == .proceed)
    }

    @Test func pristineSeedProceedsWithoutConfirmation() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()
        let disposition = try await database.writer.read { db in
            try AcceptanceGuard.disposition(db)
        }
        #expect(disposition == .proceed,
                "an untouched starter catalog is not user data")
    }

    @Test func renamedSeedRoomRequiresConfirmation() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()
        let rooms = RoomRepository(database: database)
        let fetched = try await database.writer.read { db in
            try Room.fetchOne(db, key: SeedData.rooms[0].id)
        }
        var renamed = try #require(fetched)
        renamed.name = "Owen's Garage"
        try await rooms.updateRoom(renamed)
        let disposition = try await database.writer.read { db in
            try AcceptanceGuard.disposition(db)
        }
        #expect(disposition == .requiresConfirmation)
    }

    @Test func anyContainerRequiresConfirmation() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()
        _ = try await ContainerRepository(database: database).createContainer(
            roomID: SeedData.rooms[0].id, name: "Bin", notes: nil)
        let disposition = try await database.writer.read { db in
            try AcceptanceGuard.disposition(db)
        }
        #expect(disposition == .requiresConfirmation)
    }

    @Test func deletedSeedRoomRequiresConfirmation() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()
        try await RoomRepository(database: database).deleteRooms(ids: [SeedData.rooms[0].id])
        let disposition = try await database.writer.read { db in
            try AcceptanceGuard.disposition(db)
        }
        #expect(disposition == .requiresConfirmation,
                "removing seed rows is a user decision worth protecting")
    }

    @Test func nonSeedCatalogRequiresConfirmation() async throws {
        let database = try AppDatabase.inMemory()
        _ = try await RoomRepository(database: database).createRoom(name: "Attic", icon: nil)
        let disposition = try await database.writer.read { db in
            try AcceptanceGuard.disposition(db)
        }
        #expect(disposition == .requiresConfirmation)
    }

    // MARK: Wipe and adopt (M3-E)

    @Test func wipeAndAdoptReplacesEverythingAtomically() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()
        let rooms = RoomRepository(database: database)
        let containers = ContainerRepository(database: database)
        let room = try await rooms.createRoom(name: "Attic", icon: nil)
        let bin = try await containers.createContainer(roomID: room.id, name: "Bin", notes: nil)
        _ = try await ItemRepository(database: database).createItem(
            containerID: bin.id, name: "Wrench", quantity: 1, notes: nil, categoryID: nil)
        try await database.writer.write { db in
            try SyncRole.owner.save(db)
            try RecordMetadata(recordId: room.id, recordType: .room, systemFields: Data([1]))
                .insert(db)
            try SyncState(key: SyncState.privateEngineKey, data: Data([2])).insert(db)
            try SyncState(key: SyncState.participantDisconnectedKey, data: Data([1])).insert(db)
            try SyncState(key: SyncState.archivedShareKey, data: Data([9])).insert(db)
            try AppBootstrap.chooseJoin(db)
        }

        let roster = [
            Participant(userRecordName: "_owen123", displayName: "Owen"),
            Participant(userRecordName: "_shelley456", displayName: "Shelley"),
        ]
        try await database.writer.write { db in
            try ParticipantBootstrap.wipeAndAdopt(
                db, zoneOwnerName: "_owen123", roster: roster)
        }

        struct Snapshot: Sendable {
            var rows: [Int]
            var privateEngine: SyncState?
            var disconnected: SyncState?
            var archivedShare: SyncState?
            var joinPending: Setting?
            var role: SyncRole?
            var participants: Int
            var receipts: [SyncEvent]
        }
        let snapshot = try await database.writer.read { db in
            Snapshot(
                rows: [
                    try Room.fetchCount(db), try Container.fetchCount(db),
                    try Item.fetchCount(db), try Category.fetchCount(db),
                    try PendingChange.fetchCount(db), try RecordMetadata.fetchCount(db),
                    try OrphanedRecord.fetchCount(db),
                ],
                privateEngine: try SyncState.fetchOne(db, key: SyncState.privateEngineKey),
                disconnected: try SyncState.fetchOne(db, key: SyncState.participantDisconnectedKey),
                archivedShare: try SyncState.fetchOne(db, key: SyncState.archivedShareKey),
                joinPending: try Setting.fetchOne(db, key: Setting.joinPendingKey),
                role: try SyncRole.load(db),
                participants: try Participant.fetchCount(db),
                receipts: try SyncEvent.fetchAll(db))
        }
        #expect(snapshot.rows == [0, 0, 0, 0, 0, 0, 0],
                "catalog, queue, and bookkeeping must all clear — queued local changes must never push into the household zone")
        #expect(snapshot.privateEngine == nil)
        #expect(snapshot.disconnected == nil)
        #expect(snapshot.archivedShare == nil)
        #expect(snapshot.joinPending == nil)
        #expect(snapshot.role == .participant(zoneOwnerName: "_owen123"))
        #expect(snapshot.participants == 2)
        #expect(snapshot.receipts.contains { $0.kind == .joinedHousehold })
    }

    // MARK: created_by (M3-F, D11)

    @Test func inboundApplyPersistsCreatedBy() async throws {
        let database = try AppDatabase.inMemory()
        let now = Date()
        let room = Room(
            id: AppDatabase.newID(), name: "From Owen", sortOrder: 0, icon: nil,
            createdAt: now, updatedAt: now, createdBy: "_owen123")
        try await database.applyServerChanges { apply in
            try apply.upsert(.room(room))
        }
        let stored = try await database.writer.read { db in
            try Room.fetchOne(db, key: room.id)
        }
        #expect(stored?.createdBy == "_owen123")
    }

    @Test func defaultOwnerResolvesToYouForTheOwner() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try SyncRole.owner.save(db)
        }
        let name = try await database.writer.read { db in
            try Participant.displayName(db, createdBy: CKCurrentUserDefaultName)
        }
        #expect(name == "You")
    }

    @Test func defaultOwnerResolvesToZoneOwnerForParticipants() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try SyncRole.participant(zoneOwnerName: "_owen123").save(db)
            try Participant.replaceAll(db, with: [
                Participant(userRecordName: "_owen123", displayName: "Owen"),
            ])
        }
        let name = try await database.writer.read { db in
            try Participant.displayName(db, createdBy: CKCurrentUserDefaultName)
        }
        #expect(name == "Owen", "__defaultOwner__ names the zone owner, not the reader")
    }

    @Test func ownRecordNameResolvesToYou() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try SyncRole.participant(zoneOwnerName: "_owen123").save(db)
            _ = try SyncIdentityBookkeeping.reconcile(
                db,
                current: SyncIdentityFingerprint(
                    userRecordName: "_shelley456", environment: "production"))
        }
        let name = try await database.writer.read { db in
            try Participant.displayName(db, createdBy: "_shelley456")
        }
        #expect(name == "You")
    }

    @Test func rosterResolvesOtherParticipants() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try SyncRole.owner.save(db)
            try Participant.replaceAll(db, with: [
                Participant(userRecordName: "_shelley456", displayName: "Shelley"),
            ])
        }
        let name = try await database.writer.read { db in
            try Participant.displayName(db, createdBy: "_shelley456")
        }
        #expect(name == "Shelley")
    }

    @Test func unresolvableCreatorShowsNothing() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try SyncRole.owner.save(db)
        }
        let unknown = try await database.writer.read { db in
            try Participant.displayName(db, createdBy: "_stranger999")
        }
        #expect(unknown == nil)
        let missing = try await database.writer.read { db in
            try Participant.displayName(db, createdBy: nil)
        }
        #expect(missing == nil)
    }

    // MARK: Reset is owner-only (M3-D, Owen's ruling)

    @Test func ownerCanResetCatalog() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()
        try await database.writer.write { db in
            try SyncRole.owner.save(db)
        }
        _ = try await RoomRepository(database: database).createRoom(name: "Attic", icon: nil)
        try await SettingsRepository(database: database).resetCatalogAndReseed()
        let roomCount = try await database.writer.read { db in try Room.fetchCount(db) }
        #expect(roomCount == SeedData.rooms.count)
    }

    @Test func participantResetIsRefused() async throws {
        let database = try AppDatabase.inMemory()
        let room = Room(
            id: AppDatabase.newID(), name: "Household Room", sortOrder: 0, icon: nil,
            createdAt: Date(), updatedAt: Date(), createdBy: nil)
        try await database.applyServerChanges { apply in
            try apply.upsert(.room(room))
        }
        try await database.writer.write { db in
            try SyncRole.participant(zoneOwnerName: "_owen123").save(db)
        }
        await #expect(throws: SettingsRepository.ResetNotAllowed.self) {
            try await SettingsRepository(database: database).resetCatalogAndReseed()
        }
        let (roomCount, pendingCount) = try await database.writer.read { db in
            (try Room.fetchCount(db), try PendingChange.fetchCount(db))
        }
        #expect(roomCount == 1, "a refused reset touches nothing")
        #expect(pendingCount == 0)
    }
}
