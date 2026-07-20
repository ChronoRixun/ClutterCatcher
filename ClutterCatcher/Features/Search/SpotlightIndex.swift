import Foundation
import GRDB

// M7b (U8): the pure half of Core Spotlight indexing. The index is derived,
// rebuildable local state — nothing here writes to the database, and nothing
// in the sync contract or the DL20 write paths knows it exists. The seam is
// observation-driven: `SpotlightCatalog.entries` is a plain fetch, so every
// commit from EITHER write path (LocalMutation and ServerApply alike) lands
// in the index through one ValueObservation in `SpotlightIndexer` — no
// commit-point hooks, no way for an index failure to touch a catalog write.

/// One searchable thing, as plain data. `identifier` is the entry's deep
/// link (`cluttercatcher://c/<uuid>`, items adding `?item=<uuid>` — U14), so
/// a tapped result routes through the existing URL vocabulary with no lookup
/// table: DL5 stack-replace, exactly like a QR scan.
struct SpotlightEntry: Equatable, Sendable {
    enum Domain: String, Sendable {
        case container, item
    }

    var identifier: String
    var domain: Domain
    var title: String
    var contentDescription: String
    var keywords: [String]
    /// The `photo_asset_ref` whose cached thumbnail illustrates the result,
    /// when one exists locally (resolved at index time — see
    /// `SpotlightIndexer.thumbnailURL`).
    var thumbnailRef: String?
}

/// Builds the full searchable snapshot of the catalog: every container
/// (name, its room, cover thumbnail) and every item (name, room → container
/// path, category keyword, photo thumbnail). U8 indexes containers and
/// items; categories are findable through their items' keywords and browse
/// in-app (U13).
enum SpotlightCatalog {
    static func entries(_ db: Database) throws -> [SpotlightEntry] {
        var entries: [SpotlightEntry] = []

        let containers = try ContainerIndexRow.fetchAll(
            db,
            sql: """
                SELECT containers.id, containers.name,
                       rooms.name AS room_name,
                       cover.photo_asset_ref AS cover_photo_asset_ref
                FROM containers
                JOIN rooms ON rooms.id = containers.room_id
                LEFT JOIN items AS cover ON cover.id = containers.cover_item_id
                ORDER BY containers.id
                """)
        for row in containers {
            entries.append(SpotlightEntry(
                identifier: containerIdentifier(containerID: row.id),
                domain: .container,
                title: row.name,
                contentDescription: row.roomName,
                keywords: [row.roomName],
                thumbnailRef: row.coverPhotoAssetRef))
        }

        let items = try ItemIndexRow.fetchAll(
            db,
            sql: """
                SELECT items.id, items.name, items.container_id, items.photo_asset_ref,
                       containers.name AS container_name,
                       rooms.name AS room_name,
                       categories.name AS category_name
                FROM items
                JOIN containers ON containers.id = items.container_id
                JOIN rooms ON rooms.id = containers.room_id
                LEFT JOIN categories ON categories.id = items.category_id
                ORDER BY items.id
                """)
        for row in items {
            var keywords = [row.containerName, row.roomName]
            if let category = row.categoryName {
                keywords.append(category)
            }
            entries.append(SpotlightEntry(
                identifier: itemIdentifier(containerID: row.containerId, itemID: row.id),
                domain: .item,
                title: row.name,
                contentDescription: "\(row.roomName) → \(row.containerName)",
                keywords: keywords,
                thumbnailRef: row.photoAssetRef))
        }
        return entries
    }

    /// `cluttercatcher://c/<uuid>` — the printed-label vocabulary, verbatim.
    static func containerIdentifier(containerID: String) -> String {
        "\(QRPayload.scheme)://\(QRPayload.containerHost)/\(containerID)"
    }

    /// The container link plus U14's highlight query.
    static func itemIdentifier(containerID: String, itemID: String) -> String {
        "\(containerIdentifier(containerID: containerID))?\(Route.highlightQueryName)=\(itemID)"
    }

    private struct ContainerIndexRow: FetchableRecord {
        var id: String
        var name: String
        var roomName: String
        var coverPhotoAssetRef: String?

        init(row: Row) {
            id = row["id"]
            name = row["name"]
            roomName = row["room_name"]
            coverPhotoAssetRef = row["cover_photo_asset_ref"]
        }
    }

    private struct ItemIndexRow: FetchableRecord {
        var id: String
        var name: String
        var containerId: String
        var photoAssetRef: String?
        var containerName: String
        var roomName: String
        var categoryName: String?

        init(row: Row) {
            id = row["id"]
            name = row["name"]
            containerId = row["container_id"]
            photoAssetRef = row["photo_asset_ref"]
            containerName = row["container_name"]
            roomName = row["room_name"]
            categoryName = row["category_name"]
        }
    }
}

/// What one snapshot means for the live index, against what was last
/// written: changed/new entries to (re)index, vanished identifiers to
/// prune. Deletion pruning, the reset/join wipes, and a participant's
/// kept-catalog degrade all fall out of this one diff — the index simply
/// follows the database.
enum SpotlightDiff {
    struct Changes: Equatable, Sendable {
        var upserts: [SpotlightEntry] = []
        var deletedIdentifiers: [String] = []

        var isEmpty: Bool { upserts.isEmpty && deletedIdentifiers.isEmpty }
    }

    static func changes(
        from previous: [String: SpotlightEntry],
        to current: [SpotlightEntry]
    ) -> Changes {
        var changes = Changes()
        var seen = Set<String>()
        for entry in current {
            seen.insert(entry.identifier)
            if previous[entry.identifier] != entry {
                changes.upserts.append(entry)
            }
        }
        changes.deletedIdentifiers = previous.keys
            .filter { !seen.contains($0) }
            .sorted()
        return changes
    }
}
