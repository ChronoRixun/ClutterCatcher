import SwiftUI

@main
struct ClutterCatcherApp: App {
    private let bootResult: Result<AppDatabase, Error>
    @State private var router = Router()

    init() {
        bootResult = Result {
            let database = try AppDatabase.onDisk()
            try Seeder(database: database).seedIfNeeded()
            return database
        }
        if case .failure(let error) = bootResult {
            Log.app.critical("Database bootstrap failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            switch bootResult {
            case .success(let database):
                RootView()
                    .environment(\.appDatabase, database)
                    .environment(router)
                    .onOpenURL { url in
                        router.open(url: url)
                    }
            case .failure(let error):
                BootFailureView(error: error)
            }
        }
    }
}

/// Shown only if the database can't be opened or migrated — should never
/// happen in practice, but a blank screen would be worse.
private struct BootFailureView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label("Something's Broken", systemImage: "exclamationmark.triangle")
        } description: {
            Text("ClutterCatcher couldn't open its database. Try relaunching the app.\n\n\(error.localizedDescription)")
        }
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// The app database, injected at the root. The default is a throwaway
    /// in-memory database so previews and out-of-tree views never touch the
    /// real store; `try!` is safe because opening an in-memory SQLite
    /// database only fails if SQLite itself is broken.
    @Entry var appDatabase: AppDatabase = try! .inMemory()
}
