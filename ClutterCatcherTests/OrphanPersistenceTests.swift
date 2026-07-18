import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// M3-G: the FK-orphan buffer lives in `orphaned_records`, so a crash
/// between a fetch batch and the drain can't lose records — which matters
/// most during a participant's large, unordered bootstrap hydration.
@Suite struct OrphanPersistenceTests {
    private let stamp = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func orphanItem(containerId: String, categoryId: String? = nil) -> ParsedServerRecord {
        ParsedServerRecord(
            row: .item(Item(
                id: AppDatabase.newID(), containerId: containerId, name: "Early Bird",
                quantity: 2, notes: "boxed", categoryId: categoryId, photoAssetRef: nil,
                createdAt: stamp, updatedAt: stamp, createdBy: "_owen123")),
            systemFields: Data([7, 7, 7]))
    }

    @MainActor private func makeCoordinator(_ database: AppDatabase) -> SyncCoordinator {
        SyncCoordinator(database: database, status: SyncStatusModel())
    }

    // MARK: Round-trip

    @Test func parsedRecordRoundTripsThroughTheTable() async throws {
        let database = try AppDatabase.inMemory()
        let original = orphanItem(containerId: "NOT-YET-ARRIVED")
        try await database.writer.write { [stamp] db in
            try OrphanedRecord.buffer(db, records: [original], at: stamp)
        }
        let loaded = try await database.writer.read { db in
            try OrphanedRecord.loadAll(db)
        }
        #expect(loaded == [original],
                "row values and system fields must survive the persistence round-trip")
    }

    @Test func reBufferingSameRecordKeepsOneRow() async throws {
        let database = try AppDatabase.inMemory()
        let first = orphanItem(containerId: "NOT-YET-ARRIVED")
        try await database.writer.write { [stamp] db in
            try OrphanedRecord.buffer(db, records: [first], at: stamp)
        }
        guard case .item(var item) = first.row else {
            Issue.record("expected an item")
            return
        }
        item.name = "Newer Fetch"
        let second = ParsedServerRecord(row: .item(item), systemFields: first.systemFields)
        try await database.writer.write { [stamp] db in
            try OrphanedRecord.buffer(db, records: [second], at: stamp)
        }
        let loaded = try await database.writer.read { db in
            try OrphanedRecord.loadAll(db)
        }
        #expect(loaded.count == 1)
        #expect(loaded.first?.row.displayName == "Newer Fetch", "newest fetch wins")
    }

    @Test func undecodablePayloadIsPrunedNotFatal() async throws {
        let database = try AppDatabase.inMemory()
        try await database.writer.write { [stamp] db in
            try OrphanedRecord(
                recordId: "BROKEN", recordType: .item,
                payload: Data([0xDE, 0xAD]), systemFields: Data([1]),
                bufferedAt: stamp
            ).insert(db)
        }
        // loadAll prunes as it reads, so it needs a write connection.
        let loaded = try await database.writer.write { db in
            try OrphanedRecord.loadAll(db)
        }
        #expect(loaded.isEmpty)
        let remaining = try await database.writer.read { db in
            try OrphanedRecord.fetchCount(db)
        }
        #expect(remaining == 0, "unreadable rows are pruned so they can't wedge the drain")
    }

    // MARK: Drain (the same entry point coordinator start uses)

    @Test func drainAppliesOrphanOnceParentExists() async throws {
        let database = try AppDatabase.inMemory()
        let coordinator = await makeCoordinator(database)

        let container = Container(
            id: AppDatabase.newID(), roomId: AppDatabase.newID(), name: "Bin",
            notes: nil, labelSlot: nil, createdAt: stamp, updatedAt: stamp, createdBy: nil)
        let record = orphanItem(containerId: container.id)
        try await database.writer.write { [stamp] db in
            try OrphanedRecord.buffer(db, records: [record], at: stamp)
        }

        // Parent still missing: the drain keeps the record buffered.
        await coordinator.drainOrphans(fetchComplete: false)
        var counts = try await database.writer.read { db in
            (items: try Item.fetchCount(db), buffered: try OrphanedRecord.fetchCount(db))
        }
        #expect(counts.items == 0)
        #expect(counts.buffered == 1, "mid-fetch, an unresolved orphan keeps waiting")

        // Parent arrives (with its own parent room); the next drain — the
        // same call coordinator start makes — applies the buffered item.
        try await database.applyServerChanges { [stamp] apply in
            let room = Room(
                id: container.roomId, name: "Garage", sortOrder: 0, icon: nil,
                createdAt: stamp, updatedAt: stamp, createdBy: nil)
            try apply.upsert(.room(room))
            try apply.upsert(.container(container))
        }
        await coordinator.drainOrphans(fetchComplete: false)
        counts = try await database.writer.read { db in
            (items: try Item.fetchCount(db), buffered: try OrphanedRecord.fetchCount(db))
        }
        #expect(counts.items == 1)
        #expect(counts.buffered == 0, "applied orphans leave the table")

        let metadata = try await database.writer.read { db in
            try RecordMetadata.fetchOne(db, key: record.row.id)?.systemFields
        }
        #expect(metadata == record.systemFields,
                "an applied orphan gets its ack bookkeeping like any fetched record")
    }

    @Test func fetchCompleteSalvagesItemMissingOnlyItsCategory() async throws {
        let database = try AppDatabase.inMemory()
        let coordinator = await makeCoordinator(database)

        let roomID = AppDatabase.newID()
        let container = Container(
            id: AppDatabase.newID(), roomId: roomID, name: "Bin",
            notes: nil, labelSlot: nil, createdAt: stamp, updatedAt: stamp, createdBy: nil)
        try await database.applyServerChanges { [stamp] apply in
            let room = Room(
                id: roomID, name: "Garage", sortOrder: 0, icon: nil,
                createdAt: stamp, updatedAt: stamp, createdBy: nil)
            try apply.upsert(.room(room))
            try apply.upsert(.container(container))
        }
        let record = orphanItem(containerId: container.id, categoryId: "NO-SUCH-CATEGORY")
        try await database.writer.write { [stamp] db in
            try OrphanedRecord.buffer(db, records: [record], at: stamp)
        }

        await coordinator.drainOrphans(fetchComplete: true)

        let salvaged = try await database.writer.read { db in
            try Item.fetchOne(db, key: record.row.id)
        }
        #expect(salvaged != nil)
        #expect(salvaged?.categoryId == nil, "the dead category reference is dropped, not the item")
        let buffered = try await database.writer.read { db in
            try OrphanedRecord.fetchCount(db)
        }
        #expect(buffered == 0)
    }

    @Test func fetchCompleteDropsRecordWhoseParentIsGoneWithReceipt() async throws {
        let database = try AppDatabase.inMemory()
        let coordinator = await makeCoordinator(database)
        let record = orphanItem(containerId: "GENUINELY-GONE")
        try await database.writer.write { [stamp] db in
            try OrphanedRecord.buffer(db, records: [record], at: stamp)
        }

        await coordinator.drainOrphans(fetchComplete: true)

        let (itemCount, bufferedCount, receipts) = try await database.writer.read { db in
            (try Item.fetchCount(db),
             try OrphanedRecord.fetchCount(db),
             try SyncEvent.fetchAll(db))
        }
        #expect(itemCount == 0)
        #expect(bufferedCount == 0, "a completed fetch settles the buffer either way")
        #expect(receipts.count == 1)
        #expect(receipts.first?.kind == .serverRecordDropped)
        #expect(receipts.first?.summary.contains("Early Bird") == true)
    }
}
