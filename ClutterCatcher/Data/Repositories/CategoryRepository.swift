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
