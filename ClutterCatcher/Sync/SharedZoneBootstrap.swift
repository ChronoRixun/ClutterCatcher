import CloudKit
import Foundation
import GRDB

/// M6.2 §3 — the participant second-device gap. CKShare acceptance is
/// per-Apple-ID, not per-device: a fresh install on an already-participant
/// account has the shared `Household` zone sitting in its shared database
/// already, and the acceptance callback DL29's join flow waits for will
/// never fire. "Join a household" therefore also *discovers*: when the zone
/// is already there, the device adopts the participant role directly —
/// the same decision table and the same one-transaction wipe-and-adopt as
/// acceptance (DL33), no invite required. When it isn't, the invite-waiting
/// flow stands untouched.
enum SharedZoneBootstrap {
    /// What a discovery result means for a joining device. Pure decision
    /// logic — seam-tested without CloudKit (the kickoff's §3 tests).
    enum Outcome: Equatable, Sendable {
        /// Zone present, nothing at risk on this device — adopt silently
        /// (the DL33 pristine-seed path).
        case adopt
        /// Zone present but this device carries real data — the DL33
        /// "replaces this device's catalog" dialog decides.
        case confirmBeforeAdopt
        /// No shared zone in this account's shared database — the existing
        /// invite-waiting flow stands.
        case waitForInvite
    }

    static func outcome(
        zoneDiscovered: Bool, disposition: AcceptanceGuard.Disposition
    ) -> Outcome {
        guard zoneDiscovered else { return .waitForInvite }
        switch disposition {
        case .proceed: return .adopt
        case .requiresConfirmation: return .confirmBeforeAdopt
        }
    }
}

/// A `Household` zone found in this account's shared database: everything
/// the DL33 wipe-and-adopt needs that acceptance would otherwise have
/// carried on the accepted share.
struct DiscoveredHouseholdZone: Sendable {
    let zoneOwnerName: String
    let roster: [Participant]
}

/// The CloudKit half of discovery, isolated so the decision logic above
/// stays CloudKit-free. Read-only against the shared database — no schema,
/// no writes, the DL20 paths and the engine untouched.
enum SharedZoneDiscovery {
    /// Finds the household zone, if this account already has one. The
    /// roster ride-along is best-effort: inbound sync refreshes it from the
    /// fetched CKShare record anyway (DL32), so a share fetch failure just
    /// means no `created_by` names until the first fetch lands.
    static func discoverHouseholdZone(
        in container: CKContainer
    ) async throws -> DiscoveredHouseholdZone? {
        let zones = try await container.sharedCloudDatabase.allRecordZones()
        guard let zone = zones.first(where: { $0.zoneID.zoneName == RecordMapper.zoneName })
        else {
            return nil
        }
        var roster: [Participant] = []
        if let record = try? await container.sharedCloudDatabase.record(
            for: HouseholdShare.shareRecordID(in: zone.zoneID)),
            let share = record as? CKShare {
            roster = HouseholdShare.roster(from: share)
        }
        return DiscoveredHouseholdZone(
            zoneOwnerName: zone.zoneID.ownerName, roster: roster)
    }
}
