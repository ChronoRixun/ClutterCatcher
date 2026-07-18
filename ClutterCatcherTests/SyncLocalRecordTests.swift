import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// The three local-only sync tables got their record types in M2 (DL2);
/// these prove each struct round-trips through the v1 schema unchanged.
@Suite struct SyncLocalRecordTests {
    @Test func syncStateRoundTripsAndReplaces() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try SyncState(key: SyncState.privateEngineKey, data: Data([1, 2, 3]))
                .insert(db, onConflict: .replace)
            try SyncState(key: SyncState.privateEngineKey, data: Data([9, 9]))
                .insert(db, onConflict: .replace)
        }
        let stored = try database.writer.read { db in
            try SyncState.fetchOne(db, key: SyncState.privateEngineKey)
        }
        #expect(stored?.data == Data([9, 9]))
        let count = try database.writer.read { db in try SyncState.fetchCount(db) }
        #expect(count == 1)
    }

    @Test func recordMetadataRoundTrips() throws {
        let database = try AppDatabase.inMemory()
        let id = AppDatabase.newID()
        try database.writer.write { db in
            try RecordMetadata(recordId: id, recordType: .container, systemFields: Data([7]))
                .insert(db)
        }
        let stored = try database.writer.read { db in
            try RecordMetadata.fetchOne(db, key: id)
        }
        #expect(stored?.recordType == .container)
        #expect(stored?.systemFields == Data([7]))
    }

    @Test func pendingChangeRoundTripsWithKindAndDate() throws {
        let database = try AppDatabase.inMemory()
        let id = AppDatabase.newID()
        let queuedAt = Date()
        try database.writer.write { db in
            try PendingChange(
                recordId: id, recordType: .item, changeKind: .delete, queuedAt: queuedAt
            ).insert(db)
        }
        let stored = try database.writer.read { db in
            try PendingChange.fetchOne(db, key: id)
        }
        #expect(stored?.recordType == .item)
        #expect(stored?.changeKind == .delete)
        // GRDB stores dates at millisecond precision; equality within 2 ms.
        let storedQueuedAt = try #require(stored?.queuedAt)
        #expect(abs(storedQueuedAt.timeIntervalSince(queuedAt)) < 0.002)
    }

    @Test func pendingChangeReplaceCollapsesToLatestKind() throws {
        let database = try AppDatabase.inMemory()
        let id = AppDatabase.newID()
        try database.writer.write { db in
            try PendingChange(recordId: id, recordType: .room, changeKind: .save, queuedAt: Date())
                .insert(db, onConflict: .replace)
            try PendingChange(recordId: id, recordType: .room, changeKind: .delete, queuedAt: Date())
                .insert(db, onConflict: .replace)
        }
        let stored = try database.writer.read { db in
            try PendingChange.fetchAll(db)
        }
        #expect(stored.count == 1)
        #expect(stored.first?.changeKind == .delete)
    }
}
