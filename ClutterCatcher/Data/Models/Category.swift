import Foundation
import GRDB

/// An orthogonal label for items (Tools, Seasonal, …), independent of where
/// the item lives. `colorToken` names an entry in `Tokens.categoryColor(for:)`.
struct Category: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var name: String
    var colorToken: String
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorToken = "color_token"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case createdBy = "created_by"
    }
}

extension Category: FetchableRecord, PersistableRecord {
    static let databaseTableName = "categories"
}
