import SwiftUI
import UIKit

@main
struct ClutterCatcherApp: App {
    private let bootResult: Result<AppDatabase, Error>
    private let syncCoordinator: SyncCoordinator?
    @State private var router = Router()
    @State private var syncStatus: SyncStatusModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let status = SyncStatusModel()
        _syncStatus = State(initialValue: status)
        bootResult = Result {
            let database = try AppDatabase.onDisk()
            try Seeder(database: database).seedIfNeeded()
            return database
        }
        switch bootResult {
        case .success(let database):
            // Created here, started from `.task` — the app must be fully
            // functional before (and without) any CloudKit involvement.
            syncCoordinator = SyncCoordinator(database: database, status: status)
        case .failure(let error):
            syncCoordinator = nil
            Log.app.critical("Database bootstrap failed: \(String(describing: error))")
        }
    }

    var body: some Scene {
        WindowGroup {
            switch bootResult {
            case .success(let database):
                RootView()
                    .environment(\.appDatabase, database)
                    .environment(router)
                    .environment(syncStatus)
                    .onOpenURL { url in
                        router.open(url: url)
                    }
                    .task {
                        // CKSyncEngine listens for CloudKit pushes itself;
                        // the app only has to be registered (plan §3.2).
                        UIApplication.shared.registerForRemoteNotifications()
                        await syncCoordinator?.start()
                    }
            case .failure(let error):
                BootFailureView(error: error)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, let syncCoordinator else { return }
            Task {
                await syncCoordinator.applicationDidBecomeActive()
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
