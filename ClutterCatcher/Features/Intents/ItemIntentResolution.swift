import Foundation
import GRDB

// M7b (U9): the pure half of the Find Item intent — name resolution and the
// spoken location phrase, testable without AppIntents. Read-only against the
// database (no writes from intents in this milestone).

/// An item as Siri resolves it: enough context to say where it lives and to
/// deep-link there (with U14's highlight).
struct IntentItemMatch: Identifiable, Equatable, Sendable, FetchableRecord {
    var id: String
    var name: String
    var containerID: String
    var containerName: String
    var roomName: String
    /// How many items share the container — the location phrase's "— 5
    /// items" tail.
    var containerItemCount: Int

    init(row: Row) {
        id = row["id"]
        name = row["name"]
        containerID = row["container_id"]
        containerName = row["container_name"]
        roomName = row["room_name"]
        containerItemCount = row["container_item_count"]
    }

    /// "Holiday Bins in the Garage — 5 items" (plan §2 U9). Possessive room
    /// names ("Andrew's Closet") drop the article — "in the Andrew's Closet"
    /// isn't household English.
    var locationPhrase: String {
        let room = roomName.contains("'") ? roomName : "the \(roomName)"
        let count = containerItemCount == 1 ? "1 item" : "\(containerItemCount) items"
        return "\(containerName) in \(room) — \(count)"
    }
}

enum ItemIntentResolution {
    private static let baseSelect = """
        SELECT items.id, items.name, items.container_id,
               containers.name AS container_name,
               rooms.name AS room_name,
               (SELECT COUNT(*) FROM items members
                WHERE members.container_id = items.container_id) AS container_item_count
        FROM items
        JOIN containers ON containers.id = items.container_id
        JOIN rooms ON rooms.id = containers.room_id
        """

    /// Ranked name resolution: exact matches first, then prefix, then
    /// substring — each alphabetical. Empty for no match (Siri then asks
    /// again rather than guessing).
    static func matches(_ db: Database, query: String, limit: Int = 10) throws -> [IntentItemMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let escaped = SearchRepository.escapedForLike(trimmed)
        return try IntentItemMatch.fetchAll(
            db,
            sql: baseSelect + """

                WHERE items.name LIKE ? ESCAPE '\\'
                ORDER BY CASE
                    WHEN items.name = ? COLLATE NOCASE THEN 0
                    WHEN items.name LIKE ? ESCAPE '\\' THEN 1
                    ELSE 2 END,
                    items.name COLLATE NOCASE
                LIMIT ?
                """,
            arguments: ["%\(escaped)%", trimmed, "\(escaped)%", limit])
    }

    /// The entity-by-id lookup (Shortcuts re-runs saved intents by id).
    static func entities(_ db: Database, identifiers: [String]) throws -> [IntentItemMatch] {
        guard !identifiers.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
        return try IntentItemMatch.fetchAll(
            db,
            sql: baseSelect + "\nWHERE items.id IN (\(marks))",
            arguments: StatementArguments(identifiers))
    }

    /// Donation set for the parameterized Siri phrases ("where are the
    /// Christmas lights") and the Shortcuts picker.
    static func all(_ db: Database, limit: Int = 200) throws -> [IntentItemMatch] {
        try IntentItemMatch.fetchAll(
            db,
            sql: baseSelect + "\nORDER BY items.name COLLATE NOCASE\nLIMIT ?",
            arguments: [limit])
    }
}
