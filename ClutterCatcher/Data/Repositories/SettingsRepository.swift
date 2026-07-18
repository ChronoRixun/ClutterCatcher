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
                stats.seedAppliedAt = ISO8601DateFormatter().date(from: raw)
            }
            return stats
        }
    }

    /// Deletes the entire catalog and re-applies the starter seed. Local-only
    /// tables other than the seed flag are untouched. Destructive — the
    /// Settings screen gates this behind a confirmation.
    func resetCatalogAndReseed() async throws {
        try await database.writer.write { db in
            try Item.deleteAll(db)
            try Container.deleteAll(db)
            try Room.deleteAll(db)
            try Category.deleteAll(db)
            _ = try Setting.deleteOne(db, key: Setting.seedAppliedKey)
        }
        try Seeder(database: database).seedIfNeeded()
    }
}
