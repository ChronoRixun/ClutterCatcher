import Foundation
import GRDB

/// A category with how many items carry it, for the Categories screen.
struct CategoryListEntry: Identifiable, Equatable, Sendable, FetchableRecord {
    var category: Category
    var itemCount: Int

    var id: String { category.id }

    init(row: Row) throws {
        category = try Category(row: row)
        itemCount = row["item_count"]
    }
}

// MARK: - Category browse (M7b, U13)

/// One row of the browse query: an item of the category with its container
/// and room context. The query orders room → container → item, so grouping
/// is a single ordered pass.
struct CategoryBrowseRow: Equatable, Sendable, FetchableRecord {
    var item: Item
    var containerName: String
    var roomID: String
    var roomName: String

    init(row: Row) throws {
        item = try Item(row: row)
        containerName = row["container_name"]
        roomID = row["room_id"]
        roomName = row["room_name"]
    }
}

/// Everything the category browse screen shows: the category itself and its
/// items grouped room → container (U13). Rooms follow the catalog's own
/// order (sort_order, then name); containers and items sort by name.
struct CategoryBrowse: Equatable, Sendable {
    struct ContainerGroup: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var items: [Item]
    }

    struct RoomGroup: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var containers: [ContainerGroup]
    }

    var category: Category
    var rooms: [RoomGroup]
    var itemCount: Int

    /// Groups the ordered query rows by consecutive room, then consecutive
    /// container — pure, so the shape is unit-tested without a view.
    static func grouped(_ rows: [CategoryBrowseRow]) -> [RoomGroup] {
        var rooms: [RoomGroup] = []
        for row in rows {
            if rooms.last?.id != row.roomID {
                rooms.append(RoomGroup(id: row.roomID, name: row.roomName, containers: []))
            }
            if rooms[rooms.count - 1].containers.last?.id != row.item.containerId {
                rooms[rooms.count - 1].containers.append(
                    ContainerGroup(id: row.item.containerId, name: row.containerName, items: []))
            }
            let lastRoom = rooms.count - 1
            let lastContainer = rooms[lastRoom].containers.count - 1
            rooms[lastRoom].containers[lastContainer].items.append(row.item)
        }
        return rooms
    }
}

struct CategoryRepository: Sendable {
    let database: AppDatabase

    // MARK: Observation

    func observeCategoryList() -> AsyncValueObservation<[CategoryListEntry]> {
        database.observe { db in
            try CategoryListEntry.fetchAll(db, sql: """
                SELECT categories.*, COUNT(items.id) AS item_count
                FROM categories
                LEFT JOIN items ON items.category_id = categories.id
                GROUP BY categories.id
                ORDER BY categories.name COLLATE NOCASE
                """)
        }
    }

    /// Live browse state for one category (U13); nil when the category is
    /// gone (deleted while on screen, or a stale link).
    func observeBrowse(categoryID: String) -> AsyncValueObservation<CategoryBrowse?> {
        database.observe { db in
            try Self.fetchBrowse(db, categoryID: categoryID)
        }
    }

    /// The browse fetch, callable inside any read — the grouping-query tests
    /// exercise exactly this.
    static func fetchBrowse(_ db: Database, categoryID: String) throws -> CategoryBrowse? {
        guard let category = try Category.fetchOne(db, key: categoryID) else {
            return nil
        }
        let rows = try CategoryBrowseRow.fetchAll(
            db,
            sql: """
                SELECT items.*,
                       containers.name AS container_name,
                       rooms.id AS room_id,
                       rooms.name AS room_name
                FROM items
                JOIN containers ON containers.id = items.container_id
                JOIN rooms ON rooms.id = containers.room_id
                WHERE items.category_id = ?
                ORDER BY rooms.sort_order, rooms.name COLLATE NOCASE,
                         containers.name COLLATE NOCASE,
                         items.name COLLATE NOCASE
                """,
            arguments: [categoryID])
        return CategoryBrowse(
            category: category,
            rooms: CategoryBrowse.grouped(rows),
            itemCount: rows.count)
    }

    // MARK: Reads

    func allCategories() async throws -> [Category] {
        try await database.writer.read { db in
            try Category.order(Column("name").collating(.nocase)).fetchAll(db)
        }
    }

    // MARK: Writes

    @discardableResult
    func createCategory(name: String, colorToken: String) async throws -> Category {
        let name = name.normalizedName
        return try await database.performLocalMutation { mutation in
            var category = Category(
                id: AppDatabase.newID(),
                name: name,
                colorToken: colorToken,
                createdAt: mutation.now,
                updatedAt: mutation.now,
                createdBy: nil)
            try mutation.save(&category)
            return category
        }
    }

    func updateCategory(_ category: Category) async throws {
        var category = category
        category.name = category.name.normalizedName
        try await database.performLocalMutation { [category] mutation in
            var category = category
            try mutation.save(&category)
        }
    }

    /// Deletes categories in one transaction; items that carried them keep
    /// existing with no category (cleared as tracked saves so the server
    /// never holds a dangling reference).
    func deleteCategories(ids: [String]) async throws {
        try await database.performLocalMutation { mutation in
            try mutation.deleteCategories(ids: ids)
        }
    }
}
