import Foundation
import Testing
@testable import ClutterCatcher

/// M7b rider (the Run 10 resolved question): the seeding guard's decision
/// logic and its timeout race, seam-tested without CloudKit. The invariant
/// under test: only a *proven* household interposes — every other outcome
/// (no zone, error, offline, timeout) proceeds to owner setup, so the guard
/// can never strand a genuine first owner without a network.
@Suite struct SeedingGuardTests {
    private let zone = DiscoveredHouseholdZone(
        zoneOwnerName: "OWNER",
        roster: [Participant(userRecordName: "OWNER", displayName: "Owen")])

    // MARK: The pure decision

    @Test func zoneFoundOffersTheJoin() {
        #expect(SeedingGuard.decision(.zoneFound(zone)) == .offerJoin(zone))
    }

    @Test func noZoneProceedsToOwner() {
        #expect(SeedingGuard.decision(.noZone) == .proceedToOwner)
    }

    @Test func unavailableProceedsToOwner() {
        #expect(SeedingGuard.decision(.unavailable) == .proceedToOwner)
    }

    // MARK: The discovery race

    @Test func promptDiscoveryReportsTheZone() async {
        let zone = zone
        let result = await SeedingGuard.discoveryResult { zone }
        #expect(SeedingGuard.decision(result) == .offerJoin(zone))
    }

    @Test func promptEmptyDiscoveryReportsNoZone() async {
        let result = await SeedingGuard.discoveryResult { nil }
        #expect(SeedingGuard.decision(result) == .proceedToOwner)
    }

    @Test func discoveryErrorIsUnavailable() async {
        struct Offline: Error {}
        let result = await SeedingGuard.discoveryResult { throw Offline() }
        #expect(SeedingGuard.decision(result) == .proceedToOwner)
    }

    @Test func discoveryOutlastingTheTimeoutIsUnavailable() async {
        let start = ContinuousClock.now
        let result = await SeedingGuard.discoveryResult(
            timeout: .milliseconds(50)
        ) {
            try await Task.sleep(for: .seconds(30))
            return nil
        }
        let elapsed = ContinuousClock.now - start
        #expect(SeedingGuard.decision(result) == .proceedToOwner)
        #expect(elapsed < .seconds(5),
            "the guard answers on the timeout, not the straggler")
    }
}
