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
        return try await database.writer.write { db in
            let now = Date()
            let category = Category(
                id: AppDatabase.newID(),
                name: name,
                colorToken: colorToken,
                createdAt: now,
                updatedAt: now,
                createdBy: nil)
            try category.insert(db)
            return category
        }
    }

    func updateCategory(_ category: Category) async throws {
        var category = category
        category.name = category.name.normalizedName
        category.updatedAt = Date()
        try await database.writer.write { [category] db in
            try category.update(db)
        }
    }

    /// Deletes categories in one transaction; items that carried them keep
    /// existing with no category (FK sets `items.category_id` to NULL).
    func deleteCategories(ids: [String]) async throws {
        _ = try await database.writer.write { db in
            try Category.deleteAll(db, keys: ids)
        }
    }
}
