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
