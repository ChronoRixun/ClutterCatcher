import Foundation
import Observation

/// App-level launch state (M3-B): which surface the root shows — onboarding,
/// the join-waiting screen, or the catalog — and the onboarding actions that
/// move between them. Role changes triggered elsewhere (share acceptance)
/// land here through `roleAdopted`.
@MainActor @Observable final class AppModel {
    let database: AppDatabase
    private let coordinator: SyncCoordinator
    var bootstrapState: BootstrapState
    var onboardingError: String?

    init(database: AppDatabase, coordinator: SyncCoordinator, initialState: BootstrapState) {
        self.database = database
        self.coordinator = coordinator
        self.bootstrapState = initialState
    }

    /// Onboarding: "Set up this home" — become the owner and seed (D12).
    func setUpThisHome() async {
        do {
            try await database.performLocalMutation { mutation in
                try AppBootstrap.becomeOwner(mutation)
            }
            bootstrapState = .ready(.owner)
            await coordinator.roleDidChange()
        } catch {
            Log.app.error("Owner setup failed: \(String(describing: error))")
            onboardingError = "Setting up didn't work — try again."
        }
    }

    /// Onboarding: "Join a household" — no seeding; wait for an invite.
    func chooseJoin() async {
        do {
            try await database.writer.write { db in
                try AppBootstrap.chooseJoin(db)
            }
            bootstrapState = .joinPending
            await coordinator.roleDidChange()
        } catch {
            Log.app.error("Join choice failed: \(String(describing: error))")
            onboardingError = "Saving that choice didn't work — try again."
        }
    }

    /// Called by the share-acceptance flow once a role has been adopted.
    func roleAdopted(_ role: SyncRole) {
        bootstrapState = .ready(role)
    }
}
