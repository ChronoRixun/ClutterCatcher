import Foundation
import GRDB

/// An item hit with enough context to say where the thing lives.
struct ItemSearchHit: Identifiable, Equatable, Sendable, FetchableRecord {
    var item: Item
    var containerName: String
    var roomName: String

    var id: String { item.id }

    init(row: Row) throws {
        item = try Item(row: row)
        containerName = row["container_name"]
        roomName = row["room_name"]
    }
}

struct SearchResults: Equatable, Sendable {
    var rooms: [Room] = []
    var containers: [ContainerCandidate] = []
    var items: [ItemSearchHit] = []
    var categories: [Category] = []

    var isEmpty: Bool {
        rooms.isEmpty && containers.isEmpty && items.isEmpty && categories.isEmpty
    }
}

struct SearchRepository: Sendable {
    let database: AppDatabase

    /// Live results for one query string; the observation re-emits when the
    /// underlying tables change. Matching is a case-insensitive substring
    /// match on names (and notes for containers/items).
    func observeResults(matching query: String) -> AsyncValueObservation<SearchResults> {
        let pattern = "%" + Self.escapedForLike(query) + "%"
        return database.observe { db in
            var results = SearchResults()
            results.rooms = try Room.fetchAll(
                db,
                sql: """
                    SELECT * FROM rooms
                    WHERE name LIKE ? ESCAPE '\\'
                    ORDER BY name COLLATE NOCASE
                    """,
                arguments: [pattern])
            results.containers = try ContainerCandidate.fetchAll(
                db,
                sql: """
                    SELECT containers.*, rooms.name AS room_name
                    FROM containers
                    JOIN rooms ON rooms.id = containers.room_id
                    WHERE containers.name LIKE ? ESCAPE '\\'
                       OR containers.notes LIKE ? ESCAPE '\\'
                    ORDER BY containers.name COLLATE NOCASE
                    """,
                arguments: [pattern, pattern])
            results.items = try ItemSearchHit.fetchAll(
                db,
                sql: """
                    SELECT items.*,
                           containers.name AS container_name,
                           rooms.name AS room_name
                    FROM items
                    JOIN containers ON containers.id = items.container_id
                    JOIN rooms ON rooms.id = containers.room_id
                    WHERE items.name LIKE ? ESCAPE '\\'
                       OR items.notes LIKE ? ESCAPE '\\'
                    ORDER BY items.name COLLATE NOCASE
                    """,
                arguments: [pattern, pattern])
            results.categories = try Category.fetchAll(
                db,
                sql: """
                    SELECT * FROM categories
                    WHERE name LIKE ? ESCAPE '\\'
                    ORDER BY name COLLATE NOCASE
                    """,
                arguments: [pattern])
            return results
        }
    }

    /// SQLite LIKE treats `%` and `_` as wildcards; escape them (and the
    /// escape character itself) so user input matches literally.
    static func escapedForLike(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
