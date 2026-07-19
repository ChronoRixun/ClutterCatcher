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
        categoryID: String?,
        photoAssetRef: String? = nil
    ) async throws -> Item {
        let name = name.normalizedName
        let notes = notes.normalizedNotes
        return try await database.performLocalMutation { mutation in
            var item = Item(
                id: AppDatabase.newID(),
                containerId: containerID,
                name: name,
                quantity: max(1, quantity),
                notes: notes,
                categoryId: categoryID,
                photoAssetRef: photoAssetRef,
                createdAt: mutation.now,
                updatedAt: mutation.now,
                createdBy: nil)
            try mutation.save(&item)
            return item
        }
    }

    func updateItem(_ item: Item) async throws {
        var item = item
        item.name = item.name.normalizedName
        item.quantity = max(1, item.quantity)
        item.notes = item.notes.normalizedNotes
        try await database.performLocalMutation { [item] mutation in
            var item = item
            try mutation.save(&item)
        }
    }

    /// Deletes items in one transaction.
    func deleteItems(ids: [String]) async throws {
        try await database.performLocalMutation { mutation in
            try mutation.deleteItems(ids: ids)
        }
    }
}
