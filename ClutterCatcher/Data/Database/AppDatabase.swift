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
        return try AppDatabase(DatabaseQueue(path: databaseURL.path))
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
