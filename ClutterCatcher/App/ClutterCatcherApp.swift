import SwiftUI
import UIKit

@main
struct ClutterCatcherApp: App {
    // Share acceptance arrives through the scene delegate (M3-E).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let bootResult: Result<(AppDatabase, BootstrapState), Error>
    private let syncCoordinator: SyncCoordinator?
    @State private var router = Router()
    @State private var syncStatus: SyncStatusModel
    @State private var appModel: AppModel?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let status = SyncStatusModel()
        _syncStatus = State(initialValue: status)
        bootResult = Result {
            let database = try AppDatabase.onDisk()
            let state = try database.writer.write { db in
                try AppBootstrap.adoptStateOnLaunch(db)
            }
            // Seeding is owner-path-only (D12/M3-B): a virgin database waits
            // for onboarding's choice, and participants never seed at all.
            if case .ready(.owner) = state {
                try Seeder(database: database).seedIfNeeded()
            }
            return (database, state)
        }
        switch bootResult {
        case .success(let boot):
            // Created here, started from `.task` — the app must be fully
            // functional before (and without) any CloudKit involvement.
            let coordinator = SyncCoordinator(database: boot.0, status: status)
            syncCoordinator = coordinator
            _appModel = State(initialValue: AppModel(
                database: boot.0, coordinator: coordinator, initialState: boot.1))
        case .failure(let error):
            syncCoordinator = nil
            _appModel = State(initialValue: nil)
            Log.app.critical("Database bootstrap failed: \(String(describing: error))")
        }
    }

    var body: some Scene {
        WindowGroup {
            switch bootResult {
            case .success(let boot):
                if let appModel {
                    RootView()
                        .environment(\.appDatabase, boot.0)
                        .environment(\.syncCoordinator, syncCoordinator)
                        .environment(router)
                        .environment(syncStatus)
                        .environment(appModel)
                        .onOpenURL { url in
                            router.open(url: url)
                        }
                        .task {
                            // CKSyncEngine listens for CloudKit pushes itself;
                            // the app only has to be registered (plan §3.2).
                            UIApplication.shared.registerForRemoteNotifications()
                            if let syncCoordinator {
                                ShareAcceptanceModel.shared.configure(
                                    database: boot.0,
                                    coordinator: syncCoordinator
                                ) { role in
                                    appModel.roleAdopted(role)
                                }
                                await syncCoordinator.start()
                            }
                        }
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

    /// The sync coordinator, for the few screens that talk to it directly
    /// (Family's "Leave Household"). nil in previews and on boot failure.
    @Entry var syncCoordinator: SyncCoordinator? = nil
}
