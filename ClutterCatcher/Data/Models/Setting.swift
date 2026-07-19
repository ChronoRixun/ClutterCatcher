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
    /// Present while onboarding's "Join a household" choice waits for a share
    /// invite; cleared when acceptance adopts the participant role (M3-B).
    static let joinPendingKey = "onboarding.joinPending"
    /// The selected theme's `ThemeID` raw value (M4, T2). Per-device by
    /// design — the plain settings path is exactly why theming has zero
    /// sync surface.
    static let themeIDKey = "theme_id"
}
