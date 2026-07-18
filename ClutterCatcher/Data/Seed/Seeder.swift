import Foundation
import GRDB

/// Applies the canonical starter catalog exactly once (D12).
///
/// Idempotency guards, all still required:
/// - the `settings` first-launch flag skips the whole pass on later launches;
/// - per-row existence checks make a re-run (or a run after a partial seed)
///   add nothing and overwrite nothing — existing rows are left untouched
///   and unenqueued (uploading them is backfill's job, not the seeder's).
///
/// Owner-only by design: participants bootstrap from the shared zone in M3;
/// until participants exist, the flag alone guards re-seeding.
struct Seeder: Sendable {
    let database: AppDatabase

    /// Runs synchronously; called once during app bootstrap before any UI.
    /// Goes through the mutation path so freshly seeded rows are queued for
    /// upload even when the seed happens mid-session (reset) rather than
    /// before engine start.
    func seedIfNeeded() throws {
        try database.performLocalMutationSync { mutation in
            try Self.seedIfNeeded(mutation)
        }
    }

    /// The seeding body, for callers that already hold a mutation (the reset
    /// path deletes and reseeds atomically in one).
    static func seedIfNeeded(_ mutation: LocalMutation) throws {
        if try Setting.fetchOne(mutation.db, key: Setting.seedAppliedKey) != nil {
            return
        }

        for seed in SeedData.rooms.enumerated() {
            let exists = try Room.exists(mutation.db, key: seed.element.id)
            guard !exists else { continue }
            var room = Room(
                id: seed.element.id,
                name: seed.element.name,
                sortOrder: seed.offset,
                icon: seed.element.icon,
                createdAt: mutation.now,
                updatedAt: mutation.now,
                createdBy: nil)
            try mutation.save(&room)
        }
        for seed in SeedData.categories {
            let exists = try Category.exists(mutation.db, key: seed.id)
            guard !exists else { continue }
            var category = Category(
                id: seed.id,
                name: seed.name,
                colorToken: seed.colorToken,
                createdAt: mutation.now,
                updatedAt: mutation.now,
                createdBy: nil)
            try mutation.save(&category)
        }

        // Parsed back by SettingsRepository with the matching .iso8601
        // parse strategy.
        try Setting(
            key: Setting.seedAppliedKey,
            value: mutation.now.formatted(.iso8601)
        ).insert(mutation.db, onConflict: .replace)
    }
}
