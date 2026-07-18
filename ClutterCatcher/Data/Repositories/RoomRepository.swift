import Foundation
import GRDB

/// A room together with how many containers it holds, for the Rooms home list.
struct RoomListEntry: Identifiable, Equatable, Sendable, FetchableRecord {
    var room: Room
    var containerCount: Int

    var id: String { room.id }

    init(row: Row) throws {
        room = try Room(row: row)
        containerCount = row["container_count"]
    }
}

struct RoomRepository: Sendable {
    let database: AppDatabase

    // MARK: Observation

    func observeRoomList() -> AsyncValueObservation<[RoomListEntry]> {
        database.observe { db in
            try RoomListEntry.fetchAll(db, sql: """
                SELECT rooms.*, COUNT(containers.id) AS container_count
                FROM rooms
                LEFT JOIN containers ON containers.room_id = rooms.id
                GROUP BY rooms.id
                ORDER BY rooms.sort_order, rooms.name COLLATE NOCASE
                """)
        }
    }

    func observeRoom(id: String) -> AsyncValueObservation<Room?> {
        database.observe { db in
            try Room.fetchOne(db, key: id)
        }
    }

    // MARK: Reads

    func allRooms() async throws -> [Room] {
        try await database.writer.read { db in
            try Room
                .order(Column("sort_order"), Column("name").collating(.nocase))
                .fetchAll(db)
        }
    }

    // MARK: Writes

    @discardableResult
    func createRoom(name: String, icon: String?) async throws -> Room {
        let name = name.normalizedName
        return try await database.writer.write { db in
            let nextSortOrder = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM rooms") ?? 0
            let now = Date()
            let room = Room(
                id: AppDatabase.newID(),
                name: name,
                sortOrder: nextSortOrder,
                icon: icon,
                createdAt: now,
                updatedAt: now,
                createdBy: nil)
            try room.insert(db)
            return room
        }
    }

    func updateRoom(_ room: Room) async throws {
        var room = room
        room.name = room.name.normalizedName
        room.updatedAt = Date()
        try await database.writer.write { [room] db in
            try room.update(db)
        }
    }

    /// Persists a drag-reorder: `orderedIDs` is the full room list in its new
    /// order; each room's `sort_order` becomes its index.
    func reorderRooms(orderedIDs: [String]) async throws {
        try await database.writer.write { db in
            let now = Date()
            for (index, id) in orderedIDs.enumerated() {
                try db.execute(
                    sql: """
                        UPDATE rooms SET sort_order = ?, updated_at = ?
                        WHERE id = ? AND sort_order <> ?
                        """,
                    arguments: [index, now, id, index])
            }
        }
    }

    /// Deletes rooms in one transaction; containers and their items go with
    /// them (FK cascade).
    func deleteRooms(ids: [String]) async throws {
        _ = try await database.writer.write { db in
            try Room.deleteAll(db, keys: ids)
        }
    }
}
