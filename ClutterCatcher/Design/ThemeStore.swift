import SwiftUI

/// Holds the active theme and persists the choice.
///
/// Persistence is a plain local `settings` write (T2 — DL20's "nothing to
/// stamp or queue" path): the theme is per-device, per-person, and has zero
/// sync surface by construction. The required test asserts theming produces
/// no `pending_changes` rows. The app icon is deliberately NOT persisted
/// here — `UIApplication.setAlternateIconName` is system state.
@MainActor
@Observable
final class ThemeStore {
    private(set) var theme: Theme

    @ObservationIgnored private let database: AppDatabase?

    /// `database` nil (previews/tests that don't care) keeps selection
    /// in-memory only.
    init(database: AppDatabase?, storedValue: String? = nil) {
        self.database = database
        theme = Theme.theme(forStoredValue: storedValue)
    }

    /// Reads the persisted choice synchronously — called once at boot,
    /// alongside the existing bootstrap reads.
    static func loaded(database: AppDatabase?) -> ThemeStore {
        let stored: String? = database.flatMap { database in
            try? database.writer.read { db in
                try Setting.fetchOne(db, key: Setting.themeIDKey)?.value
            }
        }
        return ThemeStore(database: database, storedValue: stored)
    }

    /// Applies the theme live, then persists. The write is fire-and-forget
    /// from the picker's point of view; a failed write costs one relaunch's
    /// worth of theming and nothing else, so it's logged, not surfaced.
    func select(_ id: ThemeID) async {
        theme = Theme.theme(for: id)
        guard let database else { return }
        do {
            try await SettingsRepository(database: database)
                .setValue(id.rawValue, forKey: Setting.themeIDKey)
        } catch {
            Log.app.error("Theme persist failed: \(String(describing: error))")
        }
    }
}
