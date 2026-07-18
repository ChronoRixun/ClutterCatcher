import Foundation
import GRDB

/// Applies the canonical starter catalog exactly once (D12).
///
/// Two idempotency guards, both required:
/// - the `settings` first-launch flag skips the whole pass on later launches;
/// - `INSERT OR IGNORE` on the fixed primary keys makes a re-run (or a run
///   after a partial seed) add nothing.
///
/// Owner-only by design: participants bootstrap from the shared zone in M3;
/// until participants exist, the flag alone guards re-seeding.
struct Seeder: Sendable {
    let database: AppDatabase

    /// Runs synchronously; called once during app bootstrap before any UI.
    func seedIfNeeded() throws {
        try database.writer.write { db in
            try Self.seedIfNeeded(db)
        }
    }

    /// The seeding body, for callers that already hold a write transaction
    /// (the reset path deletes and reseeds atomically in one).
    static func seedIfNeeded(_ db: Database) throws {
        if try Setting.fetchOne(db, key: Setting.seedAppliedKey) != nil {
            return
        }

        let now = Date()
        for seed in SeedData.rooms.enumerated() {
            let room = Room(
                id: seed.element.id,
                name: seed.element.name,
                sortOrder: seed.offset,
                icon: seed.element.icon,
                createdAt: now,
                updatedAt: now,
                createdBy: nil)
            try room.insert(db, onConflict: .ignore)
        }
        for seed in SeedData.categories {
            let category = Category(
                id: seed.id,
                name: seed.name,
                colorToken: seed.colorToken,
                createdAt: now,
                updatedAt: now,
                createdBy: nil)
            try category.insert(db, onConflict: .ignore)
        }

        // Parsed back by SettingsRepository with the matching .iso8601
        // parse strategy.
        try Setting(
            key: Setting.seedAppliedKey,
            value: now.formatted(.iso8601)
        ).insert(db, onConflict: .replace)
    }
}
