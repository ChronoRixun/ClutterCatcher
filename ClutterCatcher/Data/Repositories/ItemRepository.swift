import Foundation
import GRDB

struct ItemRepository: Sendable {
    let database: AppDatabase

    // MARK: Reads

    func fetchItem(id: String) async throws -> Item? {
        try await database.writer.read { db in
            try Item.fetchOne(db, key: id)
        }
    }

    // MARK: Writes

    @discardableResult
    func createItem(
        containerID: String,
        name: String,
        quantity: Int,
        notes: String?,
        categoryID: String?
    ) async throws -> Item {
        let name = name.normalizedName
        let notes = notes.normalizedNotes
        return try await database.writer.write { db in
            let now = Date()
            let item = Item(
                id: AppDatabase.newID(),
                containerId: containerID,
                name: name,
                quantity: max(1, quantity),
                notes: notes,
                categoryId: categoryID,
                photoAssetRef: nil,
                createdAt: now,
                updatedAt: now,
                createdBy: nil)
            try item.insert(db)
            return item
        }
    }

    func updateItem(_ item: Item) async throws {
        var item = item
        item.name = item.name.normalizedName
        item.quantity = max(1, item.quantity)
        item.notes = item.notes.normalizedNotes
        item.updatedAt = Date()
        try await database.writer.write { [item] db in
            try item.update(db)
        }
    }

    /// Deletes items in one transaction.
    func deleteItems(ids: [String]) async throws {
        _ = try await database.writer.write { db in
            try Item.deleteAll(db, keys: ids)
        }
    }
}
