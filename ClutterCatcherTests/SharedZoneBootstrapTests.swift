import Foundation
import GRDB
import Testing
@testable import ClutterCatcher

/// M6.2 §3: the participant second-device decision logic — what a
/// discovered (or absent) shared `Household` zone means for a device whose
/// user chose "Join a household". The CloudKit query lives behind
/// `SharedZoneDiscovery`; everything here runs against the real decision
/// table (`AcceptanceGuard`) on in-memory databases, no CloudKit anywhere.
@Suite struct SharedZoneBootstrapTests {
    // MARK: Zone present

    @Test func zonePresentOnVirginDatabaseAdoptsSilently() async throws {
        let database = try AppDatabase.inMemory()
        let disposition = try await database.writer.read { db in
            try AcceptanceGuard.disposition(db)
        }
        #expect(SharedZoneBootstrap.outcome(
            zoneDiscovered: true, disposition: disposition) == .adopt,
            "a fresh install on a participant Apple ID joins without an invite")
    }

    @Test func zonePresentOnPristineSeedAdoptsSilently() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()
        let disposition = try await database.writer.read { db in
            try AcceptanceGuard.disposition(db)
        }
        #expect(SharedZoneBootstrap.outcome(
            zoneDiscovered: true, disposition: disposition) == .adopt,
            "an untouched starter catalog is not user data — same as acceptance (DL33)")
    }

    @Test func zonePresentOnDataBearingDeviceRequiresTheDialog() async throws {
        let database = try AppDatabase.inMemory()
        try Seeder(database: database).seedIfNeeded()
        _ = try await ContainerRepository(database: database).createContainer(
            roomID: SeedData.rooms[0].id, name: "Bin", notes: nil)
        let disposition = try await database.writer.read { db in
            try AcceptanceGuard.disposition(db)
        }
        #expect(SharedZoneBootstrap.outcome(
            zoneDiscovered: true, disposition: disposition) == .confirmBeforeAdopt,
            "real data goes through the replace-catalog dialog, never a silent wipe")
    }

    // MARK: Zone absent — the invite-waiting flow stands

    @Test func zoneAbsentWaitsForInviteRegardlessOfCatalogState() {
        #expect(SharedZoneBootstrap.outcome(
            zoneDiscovered: false, disposition: .proceed) == .waitForInvite)
        #expect(SharedZoneBootstrap.outcome(
            zoneDiscovered: false, disposition: .requiresConfirmation) == .waitForInvite)
    }
}

/// M6.2: the extracted layout decisions (kickoff §2) — pure functions, so
/// the iPad adaptation's arithmetic is pinned without a UI test.
@Suite struct AdaptiveLayoutTests {
    @Test func compactWidthIsUnconstrained() {
        #expect(AdaptiveLayout.contentMaxWidth(isRegularWidth: false) == nil,
                "compact is the untouched iPhone layout — no cap")
    }

    @Test func regularWidthCapsAtReadableWidth() {
        #expect(AdaptiveLayout.contentMaxWidth(isRegularWidth: true)
                == AdaptiveLayout.readableMaxWidth)
    }

    @Test func gridColumnsScaleWithWidthAndClamp() {
        // Floor: even a narrow regular pane keeps two columns.
        #expect(AdaptiveLayout.roomGridColumnCount(forWidth: 0) == 2)
        #expect(AdaptiveLayout.roomGridColumnCount(forWidth: 638) == 2,
                "a 13-inch 50/50 split pane stays at two columns")
        // 11" portrait content (~794 pt) and 13" portrait content (~984 pt).
        #expect(AdaptiveLayout.roomGridColumnCount(forWidth: 794) == 2)
        #expect(AdaptiveLayout.roomGridColumnCount(forWidth: 984) == 3)
        // 13" landscape content (~1336 pt) reaches the four-column cap.
        #expect(AdaptiveLayout.roomGridColumnCount(forWidth: 1336) == 4)
        #expect(AdaptiveLayout.roomGridColumnCount(forWidth: 5000) == 4,
                "the cap holds at any window size (Stage Manager)")
    }
}
