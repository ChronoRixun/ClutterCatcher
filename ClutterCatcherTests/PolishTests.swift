import Foundation
import Testing
import UIKit
@testable import ClutterCatcher

/// M7a in-app polish (U-series): the pure logic behind the subtitle
/// threshold (U4), the label-nudge one-shot (U3), the torch button's
/// visibility/reset rules (U1), and the room icon set + fallback (U7).
@Suite struct PolishTests {

    // MARK: U4 — Rooms subtitle threshold

    @Test func subtitleIsAspirationalWhileTheCatalogHasNoContainers() {
        #expect(RoomsSubtitle.subtitle(roomCount: 1, containerCount: 0) == .aspirational)
        // Owen's seeded catalog: 12 rooms, nothing in them yet.
        #expect(RoomsSubtitle.subtitle(roomCount: 12, containerCount: 0) == .aspirational)
    }

    @Test func subtitleShowsConfidentCountsOnceAnyContainerExists() {
        #expect(
            RoomsSubtitle.subtitle(roomCount: 12, containerCount: 1)
                == .counts(rooms: 12, containers: 1))
        #expect(
            RoomsSubtitle.subtitle(roomCount: 3, containerCount: 47)
                == .counts(rooms: 3, containers: 47))
    }

    // MARK: U3 — label nudge one-shot

    @Test func nudgeOffersOnCreationNeverOnEdit() {
        var nudge = LabelNudgeState()
        nudge.containerSaved(id: "A", name: "Holiday Bins", created: false)
        #expect(nudge.offer == nil, "editing an existing container never offers")
        nudge.containerSaved(id: "A", name: "Holiday Bins", created: true)
        #expect(nudge.offer == LabelNudgeState.Offer(containerID: "A", containerName: "Holiday Bins"))
    }

    @Test func nudgeDismissClearsTheOffer() {
        var nudge = LabelNudgeState()
        nudge.containerSaved(id: "A", name: "Bin", created: true)
        nudge.dismiss()
        #expect(nudge.offer == nil)
        nudge.containerSaved(id: "A", name: "Bin", created: false)
        #expect(nudge.offer == nil, "a later edit never resurrects a dismissed offer")
    }

    @Test func nudgeNewCreationReplacesAnEarlierOffer() {
        var nudge = LabelNudgeState()
        nudge.containerSaved(id: "A", name: "Bin A", created: true)
        nudge.containerSaved(id: "B", name: "Bin B", created: true)
        #expect(nudge.offer?.containerID == "B", "one offer at a time — the newest creation")
    }

    // MARK: U1 — torch button logic

    @Test func torchButtonShowsOnlyWithTorchHardware() {
        #expect(TorchModel(isAvailable: false).buttonVisible == false)
        #expect(TorchModel(isAvailable: true).buttonVisible == true)
    }

    @Test func torchToggleFlipsOnlyWhenAvailable() {
        var torch = TorchModel(isAvailable: true)
        torch.toggle()
        #expect(torch.isOn)
        torch.toggle()
        #expect(torch.isOn == false)

        var noTorch = TorchModel(isAvailable: false)
        noTorch.toggle()
        #expect(noTorch.isOn == false, "no hardware — the model never claims an on state")
    }

    @Test func torchTurnsOffWheneverTheScannerStops() {
        var torch = TorchModel(isAvailable: true)
        torch.toggle()
        torch.scannerStopped()
        #expect(torch.isOn == false, "DL11 discipline — the torch never outlives the session")
    }

    // MARK: U7 — room icons

    @Test func roomIconSetIsCuratedUniqueAndContainsTheDefault() {
        #expect(Tokens.roomIcons.count == 24)
        #expect(Set(Tokens.roomIcons).count == Tokens.roomIcons.count)
        #expect(Tokens.roomIcons.contains(Tokens.defaultRoomIcon))
    }

    @Test @MainActor func everyRoomIconResolvesAsAnSFSymbol() {
        // A typo'd symbol name fails silently at render time (the DL55
        // lesson); this pins every curated name to a real symbol.
        for symbol in Tokens.roomIcons {
            #expect(UIImage(systemName: symbol) != nil, "\(symbol)")
        }
    }

    @Test func roomDisplayIconFallsBackToTheDefault() {
        var room = Room(
            id: "R", name: "Garage", sortOrder: 0, icon: nil,
            createdAt: Date(), updatedAt: Date(), createdBy: nil)
        #expect(room.displayIcon == Tokens.defaultRoomIcon)
        room.icon = "car"
        #expect(room.displayIcon == "car")
    }

    @Test func roomIconRoundTripsThroughTheRepositoryAndNilStaysNil() async throws {
        let database = try AppDatabase.inMemory()
        let rooms = RoomRepository(database: database)
        let created = try await rooms.createRoom(name: "Garage", icon: "car")
        var edited = created
        edited.icon = "wrench.and.screwdriver"
        try await rooms.updateRoom(edited)
        let bare = try await rooms.createRoom(name: "Attic", icon: nil)
        let all = try await rooms.allRooms()
        #expect(all.first { $0.id == created.id }?.icon == "wrench.and.screwdriver")
        // The fallback is display-only — the database keeps the honest nil.
        let bareIcon = try #require(all.first { $0.id == bare.id })
        #expect(bareIcon.icon == nil)
    }
}
