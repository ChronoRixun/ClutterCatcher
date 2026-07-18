import Foundation
import GRDB

/// A physical container — bin, drawer, shelf, box — living in one room.
/// Containers are what printed QR labels resolve to; `labelSlot` records the
/// position the label was printed at on a label sheet (nullable until printed).
struct Container: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var roomId: String
    var name: String
    var notes: String?
    var labelSlot: Int?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case name
        case notes
        case labelSlot = "label_slot"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case createdBy = "created_by"
    }
}

extension Container: FetchableRecord, PersistableRecord {
    static let databaseTableName = "containers"
}
