import Foundation
import GRDB

/// A thing stored in a container. `photoAssetRef` is reserved for M6 item
/// photos (CKAsset); it stays nil until then.
struct Item: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var containerId: String
    var name: String
    var quantity: Int
    var notes: String?
    var categoryId: String?
    var photoAssetRef: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case containerId = "container_id"
        case name
        case quantity
        case notes
        case categoryId = "category_id"
        case photoAssetRef = "photo_asset_ref"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case createdBy = "created_by"
    }
}

extension Item: FetchableRecord, PersistableRecord {
    static let databaseTableName = "items"
}
