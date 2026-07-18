import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// The in-app sync activity log (`sync_events`, local-only, v2): the durable,
/// user-visible record behind the "nothing lost silently" promise — LWW
/// losers, remote-delete casualties, dropped records, zone rebuilds.
@Suite struct SyncEventTests {
    @Test func appendRoundTripsThroughTheTable() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try SyncEvent.append(
                db, kind: .localEditOverwritten, recordType: .item,
                recordId: "SOME-ID", summary: "Wrench — replaced by a newer change.")
        }
        let events = try database.writer.read { db in
            try SyncEvent.fetchAll(db)
        }
        #expect(events.count == 1)
        #expect(events.first?.kind == .localEditOverwritten)
        #expect(events.first?.recordType == .item)
        #expect(events.first?.recordId == "SOME-ID")
        #expect(events.first?.summary.contains("Wrench") == true)
        #expect(events.first?.id != nil)
    }

    @Test func appendPrunesToTheCap() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            for index in 0..<(SyncEvent.keepCount + 5) {
                try SyncEvent.append(
                    db, kind: .zoneRecovered, recordType: nil,
                    recordId: nil, summary: "event \(index)")
            }
        }
        let (count, oldest) = try database.writer.read { db in
            (try SyncEvent.fetchCount(db),
             try SyncEvent.order(Column("id")).fetchOne(db))
        }
        #expect(count == SyncEvent.keepCount)
        #expect(oldest?.summary == "event 5", "pruning drops the oldest entries")
    }
}
