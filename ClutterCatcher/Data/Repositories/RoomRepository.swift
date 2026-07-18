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
        return try await database.performLocalMutation { mutation in
            let nextSortOrder = try Int.fetchOne(
                mutation.db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM rooms") ?? 0
            var room = Room(
                id: AppDatabase.newID(),
                name: name,
                sortOrder: nextSortOrder,
                icon: icon,
                createdAt: mutation.now,
                updatedAt: mutation.now,
                createdBy: nil)
            try mutation.save(&room)
            return room
        }
    }

    func updateRoom(_ room: Room) async throws {
        var room = room
        room.name = room.name.normalizedName
        try await database.performLocalMutation { [room] mutation in
            var room = room
            try mutation.save(&room)
        }
    }

    /// Persists a drag-reorder: `orderedIDs` is the full room list in its new
    /// order; each room whose `sort_order` actually changes becomes its index.
    func reorderRooms(orderedIDs: [String]) async throws {
        try await database.performLocalMutation { mutation in
            for (index, id) in orderedIDs.enumerated() {
                guard var room = try Room.fetchOne(mutation.db, key: id),
                      room.sortOrder != index else { continue }
                room.sortOrder = index
                try mutation.save(&room)
            }
        }
    }

    /// Deletes rooms in one transaction; containers and their items go with
    /// them (FK cascade locally, explicit queued deletes for the server).
    func deleteRooms(ids: [String]) async throws {
        try await database.performLocalMutation { mutation in
            try mutation.deleteRooms(ids: ids)
        }
    }
}
