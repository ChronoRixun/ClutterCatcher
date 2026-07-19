import Foundation
import GRDB

/// Catalog totals plus seed status, for the Settings screen.
struct CatalogStats: Equatable, Sendable {
    var roomCount = 0
    var containerCount = 0
    var itemCount = 0
    var categoryCount = 0
    var seedAppliedAt: Date?
}

/// Local-only app preferences (`settings` table) and catalog stats.
struct SettingsRepository: Sendable {
    let database: AppDatabase

    func value(forKey key: String) async throws -> String? {
        try await database.writer.read { db in
            try Setting.fetchOne(db, key: key)?.value
        }
    }

    func setValue(_ value: String, forKey key: String) async throws {
        try await database.writer.write { db in
            try Setting(key: key, value: value).insert(db, onConflict: .replace)
        }
    }

    func observeStats() -> AsyncValueObservation<CatalogStats> {
        database.observe { db in
            var stats = CatalogStats()
            stats.roomCount = try Room.fetchCount(db)
            stats.containerCount = try Container.fetchCount(db)
            stats.itemCount = try Item.fetchCount(db)
            stats.categoryCount = try Category.fetchCount(db)
            if let raw = try Setting.fetchOne(db, key: Setting.seedAppliedKey)?.value {
                stats.seedAppliedAt = try? Date(raw, strategy: .iso8601)
            }
            return stats
        }
    }

    /// Every photo ref the catalog still needs bytes for, assembled for the
    /// GC sweep's `keeping:` set (P18): every non-nil `items.photo_asset_ref`
    /// — container covers resolve through an item id, so this covers them —
    /// plus the ref of every Item row buffered in `orphaned_records`, whose
    /// bytes were materialized at buffer time and are expected on disk at
    /// drain (P9). Read-only by design (the DL20 write paths are untouched by
    /// the whole GC slice), which is why this decodes orphans directly rather
    /// than through `OrphanedRecord.loadAll` — that one prunes undecodable
    /// rows and needs a write connection. Undecodable payloads contribute no
    /// refs; their files, if any, are sweepable (the drain can never apply
    /// them either).
    func livePhotoRefs() async throws -> Set<String> {
        try await database.writer.read { db in
            var refs = Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT photo_asset_ref FROM items
                WHERE photo_asset_ref IS NOT NULL
                """))
            for orphan in try OrphanedRecord.fetchAll(db) {
                if case .item(let item) = orphan.parsedServerRecord()?.row,
                   let ref = item.photoAssetRef {
                    refs.insert(ref)
                }
            }
            return refs
        }
    }

    /// Thrown when a participant device tries to reset the shared catalog —
    /// owner-only by Owen's M3 ruling; the Settings row is disabled in
    /// participant role, this guard is the backstop.
    struct ResetNotAllowed: Error {}

    /// Deletes the entire catalog and re-applies the starter seed, atomically
    /// — one transaction, one mutation, so no observer ever sees the catalog
    /// half-gone and every removal syncs to the household as an explicit
    /// delete. Rows the seeder re-creates (fixed UUIDs) collapse back into
    /// queued saves, so their server records get overwritten, not orphaned.
    /// Destructive — the Settings screen gates this behind a confirmation,
    /// and only the household owner may run it at all (M3-D).
    func resetCatalogAndReseed() async throws {
        try await database.performLocalMutation { mutation in
            if case .participant = try SyncRole.load(mutation.db) {
                throw ResetNotAllowed()
            }
            let roomIDs = try String.fetchAll(mutation.db, sql: "SELECT id FROM rooms")
            let categoryIDs = try String.fetchAll(mutation.db, sql: "SELECT id FROM categories")
            try mutation.deleteRooms(ids: roomIDs)
            try mutation.deleteCategories(ids: categoryIDs)
            _ = try Setting.deleteOne(mutation.db, key: Setting.seedAppliedKey)
            try Seeder.seedIfNeeded(mutation)
        }
    }
}
