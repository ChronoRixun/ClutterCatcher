import Foundation
import GRDB

/// Local-only key/value storage (never synced). Used in M1 for the seed flag
/// and label-sheet preference; the other local tables (`sync_state`,
/// `record_metadata`, `pending_changes`) get their record types in M2 when
/// the sync engine consumes them.
struct Setting: Equatable, Sendable, Codable {
    var key: String
    var value: String
}

extension Setting: FetchableRecord, PersistableRecord {
    static let databaseTableName = "settings"
}

extension Setting {
    static let seedAppliedKey = "seed.v1.applied"
    static let labelSheetSpecKey = "labels.sheetSpec"
}
