import Foundation
import GRDB

/// The CloudKit record types of the four synced tables (plan §3.2). Raw
/// values are the CKRecord recordTypes that appear in the CloudKit Console.
enum SyncRecordType: String, CaseIterable, Codable, Sendable {
    case room = "Room"
    case category = "Category"
    case container = "Container"
    case item = "Item"

    var tableName: String {
        switch self {
        case .room: "rooms"
        case .category: "categories"
        case .container: "containers"
        case .item: "items"
        }
    }

    /// Parent-first order for applying inbound saves (a child's FK target
    /// lands before the child); deletes apply in the reverse order.
    static let parentsFirst: [SyncRecordType] = [.room, .category, .container, .item]
}

/// A row that syncs through the `Household` zone: its UUID-string primary key
/// doubles as the CKRecord recordName (D9). All local edits go through
/// `AppDatabase.performLocalMutation`, which owns the `updated_at` stamp.
protocol SyncedRecord: FetchableRecord, PersistableRecord, Sendable {
    static var syncRecordType: SyncRecordType { get }
    var id: String { get }
    var updatedAt: Date { get set }
}

extension Room: SyncedRecord {
    static var syncRecordType: SyncRecordType { .room }
}

extension Category: SyncedRecord {
    static var syncRecordType: SyncRecordType { .category }
}

extension Container: SyncedRecord {
    static var syncRecordType: SyncRecordType { .container }
}

extension Item: SyncedRecord {
    static var syncRecordType: SyncRecordType { .item }
}

/// One synced row with its concrete type folded in — the currency of the
/// record mapper and the inbound apply path.
enum SyncedRow: Equatable, Sendable {
    case room(Room)
    case category(Category)
    case container(Container)
    case item(Item)

    var recordType: SyncRecordType {
        switch self {
        case .room: .room
        case .category: .category
        case .container: .container
        case .item: .item
        }
    }

    var id: String {
        switch self {
        case .room(let row): row.id
        case .category(let row): row.id
        case .container(let row): row.id
        case .item(let row): row.id
        }
    }

    var updatedAt: Date {
        switch self {
        case .room(let row): row.updatedAt
        case .category(let row): row.updatedAt
        case .container(let row): row.updatedAt
        case .item(let row): row.updatedAt
        }
    }

    static func fetch(_ db: Database, type: SyncRecordType, id: String) throws -> SyncedRow? {
        switch type {
        case .room: try Room.fetchOne(db, key: id).map(SyncedRow.room)
        case .category: try Category.fetchOne(db, key: id).map(SyncedRow.category)
        case .container: try Container.fetchOne(db, key: id).map(SyncedRow.container)
        case .item: try Item.fetchOne(db, key: id).map(SyncedRow.item)
        }
    }

    /// Looks a row up by bare id — UUID keys make cross-table collisions
    /// impossible, so scanning the four tables is unambiguous.
    static func fetch(_ db: Database, id: String) throws -> SyncedRow? {
        for type in SyncRecordType.parentsFirst {
            if let row = try fetch(db, type: type, id: id) {
                return row
            }
        }
        return nil
    }
}
