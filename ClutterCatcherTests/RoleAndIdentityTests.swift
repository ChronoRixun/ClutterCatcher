import CloudKit
import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// M3-B/C: the household role, its persistence, the zone identity derived
/// from it, and the first-launch onboarding gate.
@Suite struct RoleAndIdentityTests {
    // MARK: Role persistence

    @Test func rolePersistsAndRoundTrips() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try SyncRole.participant(zoneOwnerName: "_owen123").save(db)
        }
        let loaded = try await database.writer.read { db in
            try SyncRole.load(db)
        }
        #expect(loaded == .participant(zoneOwnerName: "_owen123"))

        try await database.writer.write { db in
            try SyncRole.owner.save(db)
        }
        let overwritten = try await database.writer.read { db in
            try SyncRole.load(db)
        }
        #expect(overwritten == .owner)
    }

    @Test func roleIsNilOnFreshDatabase() async throws {
        let database = try AppDatabase.inMemory()
        let loaded = try await database.writer.read { db in
            try SyncRole.load(db)
        }
        #expect(loaded == nil)
    }

    // MARK: Dynamic zone identity (M3-C)

    @Test func ownerZoneBelongsToCurrentUser() {
        let zone = SyncRole.owner.zoneID
        #expect(zone.zoneName == "Household")
        #expect(zone.ownerName == CKCurrentUserDefaultName)
    }

    @Test func participantZoneBelongsToTheShareOwner() {
        let zone = SyncRole.participant(zoneOwnerName: "_owen123").zoneID
        #expect(zone.zoneName == "Household")
        #expect(zone.ownerName == "_owen123")
    }

    @Test func mapperBuildsRecordsInTheThreadedZone() {
        let zone = SyncRole.participant(zoneOwnerName: "_owen123").zoneID
        let now = Date()
        let room = Room(
            id: AppDatabase.newID(), name: "Garage", sortOrder: 0, icon: nil,
            createdAt: now, updatedAt: now, createdBy: nil)
        let record = RecordMapper.record(for: .room(room), systemFields: nil, zoneID: zone)
        #expect(record.recordID.zoneID.ownerName == "_owen123")
    }

    @Test func pendingChangeTargetsTheThreadedZone() throws {
        let zone = SyncRole.participant(zoneOwnerName: "_owen123").zoneID
        let pending = PendingChange(
            recordId: "ABC", recordType: .room, changeKind: .save, queuedAt: Date())
        guard case .saveRecord(let recordID) = pending.enginePendingChange(in: zone) else {
            Issue.record("expected a save")
            return
        }
        #expect(recordID.recordName == "ABC")
        #expect(recordID.zoneID.ownerName == "_owen123")

        let deletion = PendingChange(
            recordId: "DEF", recordType: .item, changeKind: .delete, queuedAt: Date())
        guard case .deleteRecord(let deleteID) = deletion.enginePendingChange(in: zone) else {
            Issue.record("expected a delete")
            return
        }
        #expect(deleteID.zoneID.ownerName == "_owen123")
    }

    // MARK: Onboarding gate (M3-B)

    @Test func virginDatabaseNeedsOnboardingAndStaysUndecided() async throws {
        let database = try AppDatabase.inMemory()
        let state = try await database.writer.write { db in
            try AppBootstrap.adoptStateOnLaunch(db)
        }
        #expect(state == .needsOnboarding)
        let role = try await database.writer.read { db in try SyncRole.load(db) }
        #expect(role == nil, "onboarding must not decide for the user")
    }

    @Test func dataBearingDatabaseAdoptsOwnerRole() async throws {
        let database = try AppDatabase.inMemory()
        _ = try await RoomRepository(database: database).createRoom(name: "Garage", icon: nil)
        let state = try await database.writer.write { db in
            try AppBootstrap.adoptStateOnLaunch(db)
        }
        #expect(state == .ready(.owner))
        let role = try await database.writer.read { db in try SyncRole.load(db) }
        #expect(role == .owner, "existing installs are owners, persisted explicitly")
    }

    @Test func seedFlagAloneAdoptsOwnerRole() async throws {
        // A seeded-then-emptied catalog is not virgin: this device owned data.
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try Setting(key: Setting.seedAppliedKey, value: "2026-07-18T00:00:00Z").insert(db)
        }
        let state = try await database.writer.write { db in
            try AppBootstrap.adoptStateOnLaunch(db)
        }
        #expect(state == .ready(.owner))
    }

    @Test func persistedRoleWinsOverEverything() async throws {
        let database = try AppDatabase.inMemory()
        _ = try await RoomRepository(database: database).createRoom(name: "Household Room", icon: nil)
        try await database.writer.write { db in
            try SyncRole.participant(zoneOwnerName: "_owen123").save(db)
        }
        let state = try await database.writer.write { db in
            try AppBootstrap.adoptStateOnLaunch(db)
        }
        #expect(state == .ready(.participant(zoneOwnerName: "_owen123")),
                "a participant with hydrated data must never flip to owner")
    }

    @Test func joinChoicePersistsAcrossLaunches() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try AppBootstrap.chooseJoin(db)
        }
        let state = try await database.writer.write { db in
            try AppBootstrap.adoptStateOnLaunch(db)
        }
        #expect(state == .joinPending)
        let role = try await database.writer.read { db in try SyncRole.load(db) }
        #expect(role == nil)
    }

    @Test func becomeOwnerSeedsAndClearsJoinChoice() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try AppBootstrap.chooseJoin(db)
        }
        try await database.performLocalMutation { mutation in
            try AppBootstrap.becomeOwner(mutation)
        }
        let (state, roomCount, pendingCount) = try await database.writer.write { db in
            (try AppBootstrap.adoptStateOnLaunch(db),
             try Room.fetchCount(db),
             try PendingChange.fetchCount(db))
        }
        #expect(state == .ready(.owner))
        #expect(roomCount == SeedData.rooms.count)
        #expect(pendingCount == SeedData.rooms.count + SeedData.categories.count,
                "the owner's seed queues for upload like any local mutation")
    }

    // MARK: Sync-identity fingerprint (M3-A)

    private let devIdentity = SyncIdentityFingerprint(
        userRecordName: "_owen123", environment: "development")
    private let prodIdentity = SyncIdentityFingerprint(
        userRecordName: "_owen123", environment: "production")

    /// A database with a catalog row, queued change, and full bookkeeping.
    private func populatedDatabase() async throws -> (AppDatabase, Room) {
        let database = try AppDatabase.inMemory()
        let room = try await RoomRepository(database: database).createRoom(name: "Garage", icon: nil)
        try await database.writer.write { db in
            try RecordMetadata(recordId: room.id, recordType: .room, systemFields: Data([1]))
                .insert(db)
            try SyncState(key: SyncState.privateEngineKey, data: Data([2])).insert(db)
            try SyncState(key: SyncState.sharedEngineKey, data: Data([3])).insert(db)
            let now = Date()
            let orphanItem = Item(
                id: AppDatabase.newID(), containerId: "GONE", name: "Buffered",
                quantity: 1, notes: nil, categoryId: nil, photoAssetRef: nil,
                createdAt: now, updatedAt: now, createdBy: nil)
            try OrphanedRecord.buffer(
                db,
                records: [ParsedServerRecord(row: .item(orphanItem), systemFields: Data([4]))],
                at: now)
        }
        return (database, room)
    }

    private func assertBookkeepingReset(_ database: AppDatabase, room: Room) async throws {
        let (metadata, engineStates, orphans, pending, rooms, receipts) =
            try await database.writer.read { db in
                (try RecordMetadata.fetchCount(db),
                 try [SyncState.privateEngineKey, SyncState.sharedEngineKey]
                     .compactMap { try SyncState.fetchOne(db, key: $0) }.count,
                 try OrphanedRecord.fetchCount(db),
                 try PendingChange.fetchCount(db),
                 try Room.fetchCount(db),
                 try SyncEvent.fetchAll(db).filter { $0.kind == .syncIdentityReset }.count)
            }
        #expect(metadata == 0, "record_metadata must reset")
        #expect(engineStates == 0, "both engine states must reset")
        #expect(orphans == 0, "buffered fetch state must reset")
        #expect(pending == 1, "pending_changes must survive — unsent edits are still edits")
        #expect(rooms == 1, "the catalog must never reset")
        #expect(receipts == 1, "exactly one receipt for the reset")
        _ = room
    }

    @Test func bookkeepingWithoutAFingerprintIsUntrustedAndResets() async throws {
        let (database, room) = try await populatedDatabase()
        let didReset = try await database.writer.write { [devIdentity] db in
            try SyncIdentityBookkeeping.reconcile(db, current: devIdentity)
        }
        #expect(didReset, "bookkeeping that no fingerprint vouches for is stale by definition")
        try await assertBookkeepingReset(database, room: room)
    }

    @Test func environmentFlipResetsExactlyBookkeeping() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { [devIdentity] db in
            let adopted = try SyncIdentityBookkeeping.reconcile(db, current: devIdentity)
            #expect(!adopted, "a fresh database just adopts the identity")
        }
        let room = try await RoomRepository(database: database).createRoom(name: "Garage", icon: nil)
        try await database.writer.write { db in
            try RecordMetadata(recordId: room.id, recordType: .room, systemFields: Data([1]))
                .insert(db)
            try SyncState(key: SyncState.privateEngineKey, data: Data([2])).insert(db)
            try SyncState(key: SyncState.sharedEngineKey, data: Data([3])).insert(db)
            let now = Date()
            let orphanItem = Item(
                id: AppDatabase.newID(), containerId: "GONE", name: "Buffered",
                quantity: 1, notes: nil, categoryId: nil, photoAssetRef: nil,
                createdAt: now, updatedAt: now, createdBy: nil)
            try OrphanedRecord.buffer(
                db,
                records: [ParsedServerRecord(row: .item(orphanItem), systemFields: Data([4]))],
                at: now)
        }
        let didReset = try await database.writer.write { [prodIdentity] db in
            try SyncIdentityBookkeeping.reconcile(db, current: prodIdentity)
        }
        #expect(didReset, "same account, different environment must reset")
        try await assertBookkeepingReset(database, room: room)
    }

    @Test func accountFlipResetsBookkeeping() async throws {
        let (database, room) = try await populatedDatabase()
        try await database.writer.write { [devIdentity] db in
            _ = try SyncIdentityBookkeeping.reconcile(db, current: devIdentity)
        }
        // Re-populate bookkeeping, then flip the account.
        try await database.writer.write { db in
            try RecordMetadata(recordId: room.id, recordType: .room, systemFields: Data([1]))
                .insert(db, onConflict: .replace)
        }
        let didReset = try await database.writer.write { db in
            try SyncIdentityBookkeeping.reconcile(
                db,
                current: SyncIdentityFingerprint(
                    userRecordName: "_shelley456", environment: "development"))
        }
        #expect(didReset)
        let metadata = try await database.writer.read { db in try RecordMetadata.fetchCount(db) }
        #expect(metadata == 0)
    }

    @Test func matchingFingerprintIsANoOp() async throws {
        let database = try AppDatabase.inMemory()
        let first = try await database.writer.write { [prodIdentity] db in
            try SyncIdentityBookkeeping.reconcile(db, current: prodIdentity)
        }
        #expect(!first, "fresh database with no bookkeeping just adopts the identity")
        let second = try await database.writer.write { [prodIdentity] db in
            try SyncIdentityBookkeeping.reconcile(db, current: prodIdentity)
        }
        #expect(!second)
        let receipts = try await database.writer.read { db in try SyncEvent.fetchCount(db) }
        #expect(receipts == 0)
    }

    @Test func legacyAccountKeyMigratesAndProductionFlipResetsOnce() async throws {
        // Owen's phone after M2: legacy account key, Development bookkeeping,
        // first launch of the Production-pinned build.
        let (database, room) = try await populatedDatabase()
        try await database.writer.write { db in
            try SyncState(key: SyncState.legacyAccountUserKey, data: Data("_owen123".utf8))
                .insert(db)
        }
        let didReset = try await database.writer.write { [prodIdentity] db in
            try SyncIdentityBookkeeping.reconcile(db, current: prodIdentity)
        }
        #expect(didReset, "same account, Development→Production is a mismatch")
        try await assertBookkeepingReset(database, room: room)
        let legacy = try await database.writer.read { db in
            try SyncState.fetchOne(db, key: SyncState.legacyAccountUserKey)
        }
        #expect(legacy == nil, "legacy key is consumed by the migration")

        // Second launch: stable.
        let again = try await database.writer.write { [prodIdentity] db in
            try SyncIdentityBookkeeping.reconcile(db, current: prodIdentity)
        }
        #expect(!again, "the reset happens exactly once")
    }

    @Test func bothComponentsFlippingResetsOnce() async throws {
        let (database, room) = try await populatedDatabase()
        try await database.writer.write { [devIdentity] db in
            _ = try SyncIdentityBookkeeping.reconcile(db, current: devIdentity)
        }
        try await database.writer.write { db in
            try RecordMetadata(recordId: room.id, recordType: .room, systemFields: Data([1]))
                .insert(db, onConflict: .replace)
        }
        let didReset = try await database.writer.write { db in
            try SyncIdentityBookkeeping.reconcile(
                db,
                current: SyncIdentityFingerprint(
                    userRecordName: "_shelley456", environment: "production"))
        }
        #expect(didReset)
    }
}

/// DL37: failures the engine won't retry must surface as an error status,
/// never hide behind an eternal "syncing…". The queue rows survive either
/// way — this is purely about the status being honest.
@Suite struct SaveFailureClassificationTests {
    @Test func schemaMissingIsPermanentAndNamesTheDeploy() {
        let message = SyncCoordinator.permanentFailureMessage(for: .invalidArguments)
        #expect(message?.contains("schema not deployed") == true,
                "the undeployed-Production case must be recognizable at a glance")
    }

    @Test func transientAndSpeciallyHandledCodesAreNotPermanent() {
        for code: CKError.Code in [
            .networkFailure, .networkUnavailable, .serviceUnavailable,
            .requestRateLimited, .zoneBusy, .notAuthenticated,
            .serverRecordChanged, .zoneNotFound, .unknownItem,
        ] {
            #expect(SyncCoordinator.permanentFailureMessage(for: code) == nil,
                    "\(code) is retried or has dedicated handling")
        }
    }

    @Test func unknownCodesFailSafeToAVisibleError() {
        #expect(SyncCoordinator.permanentFailureMessage(for: .internalError) != nil,
                "anything unclassified must still be visible, not a silent spinner")
    }
}
