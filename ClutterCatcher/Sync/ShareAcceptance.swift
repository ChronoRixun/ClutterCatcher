import CloudKit
import Foundation
import GRDB
import Observation

/// The acceptance decision table (M3-B/E): what happens to this device's
/// catalog when a share invite arrives.
enum AcceptanceGuard {
    enum Disposition: Equatable, Sendable {
        /// Fresh install or pristine starter seed — wipe silently and join.
        case proceed
        /// Real data on device — ask before replacing it with the household's.
        case requiresConfirmation
    }

    static func disposition(_ db: Database) throws -> Disposition {
        guard try AppBootstrap.hasCatalogOrSyncHistory(db) else {
            return .proceed // fresh install (incl. invite-launched first run)
        }
        return try isPristineSeed(db) ? .proceed : .requiresConfirmation
    }

    /// True when the catalog is exactly the untouched starter seed: every
    /// room and category matches its seed row, nothing added, renamed, or
    /// removed. Any deviation is user data and gets the confirmation dialog.
    static func isPristineSeed(_ db: Database) throws -> Bool {
        guard try Container.fetchCount(db) == 0,
              try Item.fetchCount(db) == 0 else {
            return false
        }
        let rooms = try Room.fetchAll(db)
        guard rooms.count == SeedData.rooms.count else { return false }
        let seedRooms = Dictionary(uniqueKeysWithValues: SeedData.rooms.map { ($0.id, $0) })
        for room in rooms {
            guard let seed = seedRooms[room.id],
                  seed.name == room.name, seed.icon == room.icon else {
                return false
            }
        }
        let categories = try Category.fetchAll(db)
        guard categories.count == SeedData.categories.count else { return false }
        let seedCategories = Dictionary(
            uniqueKeysWithValues: SeedData.categories.map { ($0.id, $0) })
        for category in categories {
            guard let seed = seedCategories[category.id],
                  seed.name == category.name, seed.colorToken == category.colorToken else {
                return false
            }
        }
        return true
    }
}

/// The local half of joining a household (M3-E): everything that must happen
/// atomically once the share acceptance has succeeded server-side.
enum ParticipantBootstrap {
    /// Wipes the catalog and all sync bookkeeping, adopts the participant
    /// role, and seeds the roster — one transaction, so a crash leaves the
    /// device either fully joined or untouched. Hydration then fills the
    /// catalog from the shared zone; nothing local ever pushes into it.
    static func wipeAndAdopt(
        _ db: Database, zoneOwnerName: String, roster: [Participant]
    ) throws {
        // Children before parents so the FK constraints hold mid-delete.
        try Item.deleteAll(db)
        try Container.deleteAll(db)
        try Room.deleteAll(db)
        try Category.deleteAll(db)
        try PendingChange.deleteAll(db)
        try RecordMetadata.deleteAll(db)
        try OrphanedRecord.deleteAll(db)
        _ = try SyncState.deleteOne(db, key: SyncState.privateEngineKey)
        _ = try SyncState.deleteOne(db, key: SyncState.sharedEngineKey)
        _ = try SyncState.deleteOne(db, key: SyncState.participantDisconnectedKey)
        _ = try SyncState.deleteOne(db, key: SyncState.archivedShareKey)
        _ = try Setting.deleteOne(db, key: Setting.joinPendingKey)
        try SyncRole.participant(zoneOwnerName: zoneOwnerName).save(db)
        try Participant.replaceAll(db, with: roster)
        try SyncEvent.append(
            db, kind: .joinedHousehold, recordType: nil, recordId: nil,
            summary: "Joined the household — this device now carries the shared catalog.")
    }
}

/// Receives share invites from the scene delegate — and, since M6.2,
/// discovers already-accepted shared zones for second devices — runs the
/// decision table, asks for confirmation when the catalog has real data,
/// then performs the (accept →) wipe → role-adopt → hydrate sequence.
/// RootView renders its phases (dialog, progress, failure).
@MainActor @Observable final class ShareAcceptanceModel {
    static let shared = ShareAcceptanceModel()

    enum Phase: Equatable {
        case idle
        /// Waiting on the "replace this device's catalog?" dialog.
        case confirming
        /// Accept + wipe + engine restart in flight.
        case joining
        case failed(message: String)
    }

    /// Where a pending join came from (M6.2): an invite carries metadata to
    /// accept server-side first; a discovered zone was accepted by this
    /// Apple ID long ago and has nothing left to accept.
    private enum PendingJoin {
        case invite(CKShare.Metadata)
        case discoveredZone(DiscoveredHouseholdZone)
    }

    private(set) var phase: Phase = .idle

    private var database: AppDatabase?
    private var coordinator: SyncCoordinator?
    private var onRoleAdopted: ((SyncRole) -> Void)?
    private var pendingJoin: PendingJoin?
    /// Invites that arrived before the app finished bootstrapping (cold
    /// launches straight from an invite link).
    private var buffered: [CKShare.Metadata] = []
    /// A discovery request that arrived before `configure` — a cold launch
    /// straight into the waiting screen runs the child view's task before
    /// the root's configure task (M6.2).
    private var wantsDiscovery = false

    func configure(
        database: AppDatabase,
        coordinator: SyncCoordinator,
        onRoleAdopted: @escaping (SyncRole) -> Void
    ) {
        self.database = database
        self.coordinator = coordinator
        self.onRoleAdopted = onRoleAdopted
        let queued = buffered
        buffered = []
        for metadata in queued {
            receive(metadata)
        }
        if wantsDiscovery {
            wantsDiscovery = false
            Task { await discoverExistingHousehold() }
        }
    }

    /// Entry point from the scene delegate (and cold-launch connection
    /// options). Everything after this is driven by the decision table.
    func receive(_ metadata: CKShare.Metadata) {
        guard let database else {
            buffered.append(metadata)
            return
        }
        guard phase == .idle || phase == .confirming else {
            Log.sync.info("Ignoring share invite while a join is in progress")
            return
        }
        // An explicit invite outranks a discovered zone awaiting confirmation.
        pendingJoin = .invite(metadata)
        Task {
            do {
                let disposition = try await database.writer.read { db in
                    try AcceptanceGuard.disposition(db)
                }
                switch disposition {
                case .proceed:
                    await performJoin()
                case .requiresConfirmation:
                    phase = .confirming
                }
            } catch {
                Log.sync.error("Acceptance guard failed: \(String(describing: error))")
                phase = .failed(message: "Couldn't read this device's catalog state.")
            }
        }
    }

    /// M6.2 §3 — the second-device path, run from the join-waiting screen.
    /// If this account's shared database already holds the `Household` zone
    /// (acceptance is per-Apple-ID; a fresh install on a participant account
    /// starts this way), join through the same decision table and phases as
    /// an invite. Quiet no-op when the zone is absent or iCloud is
    /// unreachable — the invite-waiting flow stands.
    func discoverExistingHousehold() async {
        guard let database else {
            wantsDiscovery = true // configure() re-runs this
            return
        }
        guard phase == .idle, pendingJoin == nil else { return }
        let discovered: DiscoveredHouseholdZone?
        do {
            discovered = try await SharedZoneDiscovery.discoverHouseholdZone(
                in: CKContainer(identifier: Self.containerIdentifier))
        } catch {
            Log.sync.info("Shared-zone discovery skipped: \(String(describing: error))")
            return
        }
        guard let discovered else { return } // .waitForInvite
        do {
            let disposition = try await database.writer.read { db in
                try AcceptanceGuard.disposition(db)
            }
            // A join that started while we were querying wins; don't stomp it.
            guard phase == .idle, pendingJoin == nil else { return }
            switch SharedZoneBootstrap.outcome(
                zoneDiscovered: true, disposition: disposition) {
            case .adopt:
                pendingJoin = .discoveredZone(discovered)
                await performJoin()
            case .confirmBeforeAdopt:
                pendingJoin = .discoveredZone(discovered)
                phase = .confirming
            case .waitForInvite:
                break
            }
        } catch {
            Log.sync.error("Discovery guard failed: \(String(describing: error))")
            phase = .failed(message: "Couldn't read this device's catalog state.")
        }
    }

    /// The dialog's "Join and Replace" action.
    func confirmJoin() {
        Task { await performJoin() }
    }

    /// The dialog's cancel: nothing changed; the device keeps its catalog
    /// and role.
    func cancelJoin() {
        pendingJoin = nil
        phase = .idle
    }

    func dismissFailure() {
        phase = .idle
    }

    private static let containerIdentifier = "iCloud.com.rixun.cluttercatcher"

    private func performJoin() async {
        guard let pendingJoin, let database, let coordinator else { return }
        phase = .joining
        do {
            let zoneOwnerName: String
            let roster: [Participant]
            switch pendingJoin {
            case .invite(let metadata):
                // CKContainer.accept wraps CKAcceptSharesOperation (plan
                // §3.3); accept first — if it fails, nothing local changed.
                let ckContainer = CKContainer(identifier: metadata.containerIdentifier)
                let share = try await ckContainer.accept(metadata)
                zoneOwnerName = share.recordID.zoneID.ownerName
                roster = HouseholdShare.roster(from: share)
            case .discoveredZone(let discovered):
                // Nothing to accept — this Apple ID accepted long ago; the
                // zone is already sitting in its shared database (M6.2 §3).
                zoneOwnerName = discovered.zoneOwnerName
                roster = discovered.roster
            }
            try await database.writer.write { db in
                try ParticipantBootstrap.wipeAndAdopt(
                    db, zoneOwnerName: zoneOwnerName, roster: roster)
            }
            self.pendingJoin = nil
            await coordinator.roleDidChange() // starts the shared-DB engine
            onRoleAdopted?(.participant(zoneOwnerName: zoneOwnerName))
            phase = .idle
            Log.sync.info("Joined household (zone owner \(zoneOwnerName))")
        } catch {
            Log.sync.error("Join failed: \(String(describing: error))")
            let wasInvite: Bool = {
                if case .invite = pendingJoin { return true }
                return false
            }()
            self.pendingJoin = nil
            phase = .failed(message: wasInvite
                ? "Joining the household didn't work — ask for a fresh invite and try again."
                : "Joining the household didn't work — check that iCloud is reachable and try again.")
        }
    }
}
