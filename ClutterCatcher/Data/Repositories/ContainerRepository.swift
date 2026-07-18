import Foundation
import GRDB

/// A container with its item count, for the room-detail list.
struct ContainerListEntry: Identifiable, Equatable, Sendable, FetchableRecord {
    var container: Container
    var itemCount: Int

    var id: String { container.id }

    init(row: Row) throws {
        container = try Container(row: row)
        itemCount = row["item_count"]
    }
}

/// An item with its category's display bits, for the container-detail list.
struct ItemListEntry: Identifiable, Equatable, Sendable, FetchableRecord {
    var item: Item
    var categoryName: String?
    var categoryColorToken: String?

    var id: String { item.id }

    init(row: Row) throws {
        item = try Item(row: row)
        categoryName = row["category_name"]
        categoryColorToken = row["category_color_token"]
    }
}

/// Everything the container-detail screen shows, fetched in one observation.
struct ContainerDetail: Equatable, Sendable {
    var container: Container
    var roomName: String
    var items: [ItemListEntry]
}

/// A container with its room name, for the label-sheet picker and search.
struct ContainerCandidate: Identifiable, Equatable, Sendable, FetchableRecord {
    var container: Container
    var roomName: String

    var id: String { container.id }

    init(row: Row) throws {
        container = try Container(row: row)
        roomName = row["room_name"]
    }
}

struct ContainerRepository: Sendable {
    let database: AppDatabase

    // MARK: Observation

    func observeContainers(inRoom roomID: String) -> AsyncValueObservation<[ContainerListEntry]> {
        database.observe { db in
            try ContainerListEntry.fetchAll(
                db,
                sql: """
                    SELECT containers.*, COUNT(items.id) AS item_count
                    FROM containers
                    LEFT JOIN items ON items.container_id = containers.id
                    WHERE containers.room_id = ?
                    GROUP BY containers.id
                    ORDER BY containers.name COLLATE NOCASE
                    """,
                arguments: [roomID])
        }
    }

    func observeDetail(containerID: String) -> AsyncValueObservation<ContainerDetail?> {
        database.observe { db -> ContainerDetail? in
            guard let container = try Container.fetchOne(db, key: containerID) else {
                return nil
            }
            let roomName = try String.fetchOne(
                db, sql: "SELECT name FROM rooms WHERE id = ?",
                arguments: [container.roomId]) ?? ""
            let items = try ItemListEntry.fetchAll(
                db,
                sql: """
                    SELECT items.*,
                           categories.name AS category_name,
                           categories.color_token AS category_color_token
                    FROM items
                    LEFT JOIN categories ON categories.id = items.category_id
                    WHERE items.container_id = ?
                    ORDER BY items.name COLLATE NOCASE
                    """,
                arguments: [containerID])
            return ContainerDetail(container: container, roomName: roomName, items: items)
        }
    }

    /// Every container in the catalog with its room name, for label printing.
    func observeAllCandidates() -> AsyncValueObservation<[ContainerCandidate]> {
        database.observe { db in
            try ContainerCandidate.fetchAll(db, sql: """
                SELECT containers.*, rooms.name AS room_name
                FROM containers
                JOIN rooms ON rooms.id = containers.room_id
                ORDER BY rooms.sort_order, rooms.name COLLATE NOCASE,
                         containers.name COLLATE NOCASE
                """)
        }
    }

    // MARK: Writes

    @discardableResult
    func createContainer(roomID: String, name: String, notes: String?) async throws -> Container {
        let name = name.normalizedName
        let notes = notes.normalizedNotes
        return try await database.writer.write { db in
            let now = Date()
            let container = Container(
                id: AppDatabase.newID(),
                roomId: roomID,
                name: name,
                notes: notes,
                labelSlot: nil,
                createdAt: now,
                updatedAt: now,
                createdBy: nil)
            try container.insert(db)
            return container
        }
    }

    func updateContainer(_ container: Container) async throws {
        var container = container
        container.name = container.name.normalizedName
        container.notes = container.notes.normalizedNotes
        container.updatedAt = Date()
        try await database.writer.write { [container] db in
            try container.update(db)
        }
    }

    /// Deletes containers in one transaction; their items go with them
    /// (FK cascade).
    func deleteContainers(ids: [String]) async throws {
        _ = try await database.writer.write { db in
            try Container.deleteAll(db, keys: ids)
        }
    }

    // MARK: Label slots

    /// Gives every listed container a permanent label slot if it lacks one,
    /// continuing after the highest slot already allocated. Returns each
    /// container's slot. In M2+ this runs after a sync pull so two devices
    /// don't hand out the same slot (D10 — pull-before-print).
    func assignLabelSlots(containerIDs: [String]) async throws -> [String: Int] {
        try await database.writer.write { db in
            var nextSlot = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(label_slot), 0) + 1 FROM containers") ?? 1
            var slots: [String: Int] = [:]
            let now = Date()
            for id in containerIDs {
                guard var container = try Container.fetchOne(db, key: id) else { continue }
                if let slot = container.labelSlot {
                    slots[id] = slot
                } else {
                    container.labelSlot = nextSlot
                    container.updatedAt = now
                    try container.update(db)
                    slots[id] = nextSlot
                    nextSlot += 1
                }
            }
            return slots
        }
    }
}
