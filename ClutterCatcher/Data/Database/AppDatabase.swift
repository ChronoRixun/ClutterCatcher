import Foundation
import GRDB

/// The app's database: owns the GRDB connection and the migration history.
/// All reads/writes and `ValueObservation`s go through this type, usually via
/// a repository (`RoomRepository`, `ContainerRepository`, …).
struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    // MARK: Schema (plan §3.1)

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // Synced tables: UUID-string primary keys double as CKRecord
            // recordNames (D9). `created_by` stays nil until sync (M2+).
            try db.create(table: "rooms") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("icon", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("created_by", .text)
            }

            try db.create(table: "categories") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color_token", .text).notNull().defaults(to: "gray")
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("created_by", .text)
            }

            try db.create(table: "containers") { t in
                t.primaryKey("id", .text)
                t.column("room_id", .text).notNull().indexed()
                    .references("rooms", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("notes", .text)
                t.column("label_slot", .integer)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("created_by", .text)
            }

            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
                t.column("container_id", .text).notNull().indexed()
                    .references("containers", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("quantity", .integer).notNull().defaults(to: 1)
                t.column("notes", .text)
                t.column("category_id", .text).indexed()
                    .references("categories", onDelete: .setNull)
                t.column("photo_asset_ref", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("created_by", .text)
            }

            // Local-only tables (never synced). Created now, consumed by the
            // CKSyncEngine pipeline starting in M2.
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }

            try db.create(table: "sync_state") { t in
                t.primaryKey("key", .text)
                t.column("data", .blob).notNull()
            }

            try db.create(table: "record_metadata") { t in
                t.primaryKey("record_id", .text)
                t.column("record_type", .text).notNull()
                t.column("system_fields", .blob).notNull()
            }

            try db.create(table: "pending_changes") { t in
                t.primaryKey("record_id", .text)
                t.column("record_type", .text).notNull()
                t.column("change_kind", .text).notNull()
                t.column("queued_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            // Local-only sync activity log (never synced): the user-visible
            // receipts behind "nothing lost silently" — LWW losers, remote-
            // delete casualties, dropped records, zone rebuilds. Capped by
            // SyncEvent.append.
            try db.create(table: "sync_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("occurred_at", .datetime).notNull()
                t.column("kind", .text).notNull()
                t.column("record_type", .text)
                t.column("record_id", .text)
                t.column("summary", .text).notNull()
            }
        }

        migrator.registerMigration("v3") { db in
            // Local-only share-participant roster (M3, D11): user record name
            // → display name, refreshed from CKShare.participants whenever
            // the share is fetched. Resolves `created_by` for display.
            try db.create(table: "participants") { t in
                t.primaryKey("user_record_name", .text)
                t.column("display_name", .text).notNull()
            }

            // Local-only persistence of the inbound FK-orphan buffer (M3-G):
            // records whose parent hasn't arrived yet survive a crash between
            // a fetch batch and the drain — which matters most during a
            // participant's large, unordered bootstrap hydration.
            try db.create(table: "orphaned_records") { t in
                t.primaryKey("record_id", .text)
                t.column("record_type", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("system_fields", .blob).notNull()
                t.column("buffered_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v4") { db in
            // M6 item photos (P10): a container may point at one of its items
            // as a "cover" whose photo represents it in room/container lists.
            // Additive, nullable, no backfill — existing rows get NULL. It is
            // a SOFT reference (no FK): a hard container→item FK would cycle
            // against the item→container FK in the verified parents-first
            // apply order, so display resolves it with graceful fallback.
            try db.alter(table: "containers") { t in
                t.add(column: "cover_item_id", .text)
            }
            // Note: `items.photo_asset_ref` already exists (migration v1); M6
            // only defines its meaning (P6 — a synced photo id, not a path).
            // The photo bytes ride as a CKAsset field on the Item record; the
            // local files live under Application Support/Photos and are not a
            // database concern (see Shared/PhotoStore.swift).
        }

        return migrator
    }

    // MARK: Observation

    /// A `ValueObservation` async sequence over an arbitrary fetch. The
    /// sequence emits an initial value, then a fresh one after every commit
    /// that touches the observed tables.
    func observe<Value: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncValueObservation<Value> {
        ValueObservation.tracking(fetch).values(in: writer)
    }
}

// MARK: - Connections

extension AppDatabase {
    /// The persistent on-device database, in Application Support.
    static func onDisk() throws -> AppDatabase {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appending(path: "Database", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "cluttercatcher.sqlite")
        // DatabasePool (WAL) so sync-engine writes and UI observation reads
        // coexist without blocking each other (M2). Tests and previews stay
        // on in-memory DatabaseQueue — both are DatabaseWriters.
        return try AppDatabase(DatabasePool(path: databaseURL.path))
    }

    /// An in-memory database, for tests and previews.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }
}

// MARK: - Shared helpers

extension AppDatabase {
    /// New rows get uppercase UUIDv4-string ids (D9).
    static func newID() -> String { UUID().uuidString }
}
