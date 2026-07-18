import Foundation
import GRDB

/// What the app should show at launch (M3-B): the catalog, or first-launch
/// onboarding on a virgin database.
enum BootstrapState: Equatable, Sendable {
    /// Virgin database, no choice made — show the two-path onboarding.
    case needsOnboarding
    /// "Join a household" was chosen; waiting for a share invite.
    case joinPending
    /// A role exists; the app runs normally.
    case ready(SyncRole)
}

/// First-launch gating (M3-B). Seeding is owner-path-only by construction
/// (D12): the only calls to `Seeder` live behind the owner branches here and
/// in the catalog reset — a participant device can never seed.
enum AppBootstrap {
    /// Resolves the launch state, adopting the owner role for installs that
    /// predate roles (they seeded and synced as the owner through M2).
    /// Runs in a write so the adoption persists atomically.
    static func adoptStateOnLaunch(_ db: Database) throws -> BootstrapState {
        if let role = try SyncRole.load(db) {
            return .ready(role)
        }
        if try Setting.fetchOne(db, key: Setting.joinPendingKey) != nil {
            return .joinPending
        }
        if try hasCatalogOrSyncHistory(db) {
            try SyncRole.owner.save(db)
            return .ready(.owner)
        }
        return .needsOnboarding
    }

    /// "Virgin database" means no synced rows and no sync bookkeeping. The
    /// sync-identity fingerprint deliberately doesn't count — it's written by
    /// the identity check, not by owning anything.
    static func hasCatalogOrSyncHistory(_ db: Database) throws -> Bool {
        try Room.fetchCount(db) > 0
            || Category.fetchCount(db) > 0
            || Container.fetchCount(db) > 0
            || Item.fetchCount(db) > 0
            || PendingChange.fetchCount(db) > 0
            || RecordMetadata.fetchCount(db) > 0
            || SyncState.fetchOne(db, key: SyncState.privateEngineKey) != nil
            || SyncState.fetchOne(db, key: SyncState.sharedEngineKey) != nil
            || SyncState.fetchOne(db, key: SyncState.legacyAccountUserKey) != nil
            || Setting.fetchOne(db, key: Setting.seedAppliedKey) != nil
    }

    /// Onboarding: "Set up this home". Becomes the owner and seeds — the M2
    /// behavior, chosen explicitly.
    static func becomeOwner(_ mutation: LocalMutation) throws {
        try SyncRole.owner.save(mutation.db)
        _ = try Setting.deleteOne(mutation.db, key: Setting.joinPendingKey)
        try Seeder.seedIfNeeded(mutation)
    }

    /// Onboarding: "Join a household". No seeding, ever — the device waits
    /// for a share invite (M3-B closes the participant-seeding watch-out
    /// structurally).
    static func chooseJoin(_ db: Database) throws {
        try Setting(key: Setting.joinPendingKey, value: "true")
            .insert(db, onConflict: .replace)
    }
}
