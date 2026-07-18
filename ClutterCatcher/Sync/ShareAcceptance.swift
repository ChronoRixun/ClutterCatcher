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

/// Receives share invites from the scene delegate, runs the decision table,
/// asks for confirmation when the catalog has real data, then performs the
/// accept → wipe → role-adopt → hydrate sequence. RootView renders its
/// phases (dialog, progress, failure).
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

    private(set) var phase: Phase = .idle

    private var database: AppDatabase?
    private var coordinator: SyncCoordinator?
    private var onRoleAdopted: ((SyncRole) -> Void)?
    private var pendingMetadata: CKShare.Metadata?
    /// Invites that arrived before the app finished bootstrapping (cold
    /// launches straight from an invite link).
    private var buffered: [CKShare.Metadata] = []

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
        pendingMetadata = metadata
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

    /// The dialog's "Join and Replace" action.
    func confirmJoin() {
        Task { await performJoin() }
    }

    /// The dialog's cancel: nothing changed; the device keeps its catalog
    /// and role.
    func cancelJoin() {
        pendingMetadata = nil
        phase = .idle
    }

    func dismissFailure() {
        phase = .idle
    }

    private func performJoin() async {
        guard let metadata = pendingMetadata, let database, let coordinator else { return }
        phase = .joining
        do {
            // CKContainer.accept wraps CKAcceptSharesOperation (plan §3.3);
            // accept first — if it fails, nothing local has changed.
            let ckContainer = CKContainer(identifier: metadata.containerIdentifier)
            let share = try await ckContainer.accept(metadata)
            let zoneOwnerName = share.recordID.zoneID.ownerName
            let roster = HouseholdShare.roster(from: share)
            try await database.writer.write { db in
                try ParticipantBootstrap.wipeAndAdopt(
                    db, zoneOwnerName: zoneOwnerName, roster: roster)
            }
            pendingMetadata = nil
            await coordinator.roleDidChange() // starts the shared-DB engine
            onRoleAdopted?(.participant(zoneOwnerName: zoneOwnerName))
            phase = .idle
            Log.sync.info("Joined household (zone owner \(zoneOwnerName))")
        } catch {
            Log.sync.error("Share acceptance failed: \(String(describing: error))")
            pendingMetadata = nil
            phase = .failed(
                message: "Joining the household didn't work — ask for a fresh invite and try again.")
        }
    }
}
