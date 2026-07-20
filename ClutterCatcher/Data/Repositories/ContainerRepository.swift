import Foundation
import GRDB

/// A container with its item count, for the room-detail list.
struct ContainerListEntry: Identifiable, Equatable, Sendable, FetchableRecord {
    var container: Container
    var itemCount: Int
    /// The cover item's `photo_asset_ref`, resolved through the soft
    /// `cover_item_id` pointer (M6, P10). nil when there's no cover, the cover
    /// item is gone, or it has no photo — the row then shows its normal icon
    /// (graceful fallback). The file may still be absent locally (P13); the
    /// view decides thumbnail-vs-placeholder from that.
    var coverPhotoAssetRef: String?

    var id: String { container.id }

    init(row: Row) throws {
        container = try Container(row: row)
        itemCount = row["item_count"]
        coverPhotoAssetRef = row["cover_photo_asset_ref"]
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
    /// Resolved display name for the container's `created_by`, when it
    /// resolves (M3-F); the screen shows nothing otherwise.
    var createdByName: String?
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
            // `member` fans out for the item count; `cover` is the 1:1 soft
            // cover pointer (P10). Both alias `items`, so they must be named
            // apart. `cover.photo_asset_ref` is constant across a container's
            // group (it doesn't depend on `member`), so the bare column is
            // deterministic under GROUP BY.
            try ContainerListEntry.fetchAll(
                db,
                sql: """
                    SELECT containers.*,
                           COUNT(member.id) AS item_count,
                           cover.photo_asset_ref AS cover_photo_asset_ref
                    FROM containers
                    LEFT JOIN items AS member ON member.container_id = containers.id
                    LEFT JOIN items AS cover ON cover.id = containers.cover_item_id
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
            return ContainerDetail(
                container: container,
                roomName: roomName,
                items: items,
                createdByName: try Participant.displayName(db, createdBy: container.createdBy))
        }
    }

    /// Every container in the catalog with its room name — room order, then
    /// name — for label printing and the item editor's container picker.
    private static let allCandidatesSQL = """
        SELECT containers.*, rooms.name AS room_name
        FROM containers
        JOIN rooms ON rooms.id = containers.room_id
        ORDER BY rooms.sort_order, rooms.name COLLATE NOCASE,
                 containers.name COLLATE NOCASE
        """

    func observeAllCandidates() -> AsyncValueObservation<[ContainerCandidate]> {
        database.observe { db in
            try ContainerCandidate.fetchAll(db, sql: Self.allCandidatesSQL)
        }
    }

    /// One-shot snapshot of the same list, for the item editor (U2) — the
    /// picker lives inside an editing session, so a live observation would
    /// churn state under the user for no benefit.
    func allCandidates() async throws -> [ContainerCandidate] {
        try await database.writer.read { db in
            try ContainerCandidate.fetchAll(db, sql: Self.allCandidatesSQL)
        }
    }

    // MARK: Writes

    @discardableResult
    func createContainer(roomID: String, name: String, notes: String?) async throws -> Container {
        let name = name.normalizedName
        let notes = notes.normalizedNotes
        return try await database.performLocalMutation { mutation in
            var container = Container(
                id: AppDatabase.newID(),
                roomId: roomID,
                name: name,
                notes: notes,
                labelSlot: nil,
                coverItemId: nil,
                createdAt: mutation.now,
                updatedAt: mutation.now,
                createdBy: nil)
            try mutation.save(&container)
            return container
        }
    }

    func updateContainer(_ container: Container) async throws {
        var container = container
        container.name = container.name.normalizedName
        container.notes = container.notes.normalizedNotes
        try await database.performLocalMutation { [container] mutation in
            var container = container
            try mutation.save(&container)
        }
    }

    /// A one-off read of a single container, for the item editor's
    /// "Set as Container Cover" state (M6, §6).
    func fetchContainer(id: String) async throws -> Container? {
        try await database.writer.read { db in
            try Container.fetchOne(db, key: id)
        }
    }

    /// Designates `itemID` as the container's cover (P4, Variant A), or clears
    /// it when `itemID` is nil. A tracked save on the container (its own
    /// `cover_item_id` field, P10) so the choice syncs to the household like
    /// any other container edit. No-op if the container is gone.
    func setCover(containerID: String, itemID: String?) async throws {
        try await database.performLocalMutation { mutation in
            guard var container = try Container.fetchOne(mutation.db, key: containerID) else {
                return
            }
            guard container.coverItemId != itemID else { return } // no needless edit/echo
            container.coverItemId = itemID
            try mutation.save(&container)
        }
    }

    /// Deletes containers in one transaction; their items go with them
    /// (FK cascade locally, explicit queued deletes for the server).
    func deleteContainers(ids: [String]) async throws {
        try await database.performLocalMutation { mutation in
            try mutation.deleteContainers(ids: ids)
        }
    }

    // MARK: Label slots

    /// Gives every listed container a permanent label slot if it lacks one,
    /// continuing after the highest slot already allocated. Returns each
    /// container's slot. In M2+ this runs after a sync pull so two devices
    /// don't hand out the same slot (D10 — pull-before-print).
    func assignLabelSlots(containerIDs: [String]) async throws -> [String: Int] {
        try await database.performLocalMutation { mutation in
            var nextSlot = try Int.fetchOne(
                mutation.db, sql: "SELECT COALESCE(MAX(label_slot), 0) + 1 FROM containers") ?? 1
            var slots: [String: Int] = [:]
            for id in containerIDs {
                guard var container = try Container.fetchOne(mutation.db, key: id) else { continue }
                if let slot = container.labelSlot {
                    slots[id] = slot
                } else {
                    container.labelSlot = nextSlot
                    try mutation.save(&container)
                    slots[id] = nextSlot
                    nextSlot += 1
                }
            }
            return slots
        }
    }
}
