import Foundation
import GRDB

/// A room of the house — the top of the Rooms → Containers → Items hierarchy.
///
/// `id` is an uppercase UUIDv4 string; it doubles as the future CKRecord
/// recordName (D9), so it never changes once created.
struct Room: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var name: String
    var sortOrder: Int
    var icon: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
        case icon
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case createdBy = "created_by"
    }
}

extension Room: FetchableRecord, PersistableRecord {
    static let databaseTableName = "rooms"
}
