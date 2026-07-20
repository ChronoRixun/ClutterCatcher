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
            // U2: an item moving out of a container it fronts would leave
            // the source's cover pointing at an item that's no longer
            // inside. Clear it as a tracked save in the same transaction —
            // the P11 pattern — so peers converge too.
            if let previous = try Item.fetchOne(mutation.db, key: item.id),
               previous.containerId != item.containerId,
               var source = try Container.fetchOne(mutation.db, key: previous.containerId),
               source.coverItemId == item.id {
                source.coverItemId = nil
                try mutation.save(&source)
            }
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
