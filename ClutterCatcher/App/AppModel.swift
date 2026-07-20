import CloudKit
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
    /// M7b rider: a household the seeding guard discovered on this Apple ID,
    /// awaiting the "join it instead?" choice. Both onboarding screens
    /// present the dialog off this.
    var discoveredHouseholdOffer: DiscoveredHouseholdZone?
    /// True while the guard's one discovery check runs (≤ its timeout) —
    /// the onboarding buttons disable on it.
    var isCheckingForHousehold = false

    init(database: AppDatabase, coordinator: SyncCoordinator, initialState: BootstrapState) {
        self.database = database
        self.coordinator = coordinator
        self.bootstrapState = initialState
    }

    /// Onboarding: "Set up this home" — become the owner and seed (D12),
    /// after the rider's one guarded look for an existing household. The
    /// guard can only interpose a question; every non-proof outcome
    /// (no zone, offline, timeout, error) proceeds exactly as before.
    func setUpThisHome() async {
        isCheckingForHousehold = true
        let result = await SeedingGuard.discoveryResult {
            try await SharedZoneDiscovery.discoverHouseholdZone(
                in: CKContainer(identifier: ShareAcceptanceModel.containerIdentifier))
        }
        isCheckingForHousehold = false
        switch SeedingGuard.decision(result) {
        case .offerJoin(let zone):
            discoveredHouseholdOffer = zone
        case .proceedToOwner:
            await becomeOwnerAndSeed()
        }
    }

    /// The offer's "Join Household": the discovered-zone machinery (M6.2)
    /// does the rest — same decision table, phases, and one-transaction
    /// wipe-and-adopt as an invite.
    func joinDiscoveredHousehold() async {
        guard let zone = discoveredHouseholdOffer else { return }
        discoveredHouseholdOffer = nil
        await ShareAcceptanceModel.shared.adopt(discovered: zone)
    }

    /// The offer's explicit "start a separate household anyway" — the
    /// pre-rider path, now a deliberate choice instead of a default.
    func setUpThisHomeAnyway() async {
        discoveredHouseholdOffer = nil
        await becomeOwnerAndSeed()
    }

    func dismissDiscoveredOffer() {
        discoveredHouseholdOffer = nil
    }

    private func becomeOwnerAndSeed() async {
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
