import SwiftUI

/// One room: its containers, with item counts.
struct RoomDetailView: View {
    let roomID: String

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var room: Room?
    @State private var roomLoaded = false
    @State private var containers: [ContainerListEntry] = []
    @State private var isAddingContainer = false
    @State private var isEditingRoom = false
    /// Fen's ear-perk on the empty state's primary button (§5 M4b — the
    /// same "Add Your First Room" pattern; Cozy and Pop! only).
    @State private var fenPerkTrigger = 0
    /// U3: the one-shot "Print a label for this bin?" offer, plus the
    /// print flow it opens with that container preselected.
    @State private var labelNudge = LabelNudgeState()
    @State private var printingOffer: LabelNudgeState.Offer?

    private var roomRepository: RoomRepository { RoomRepository(database: appDatabase) }
    private var containerRepository: ContainerRepository { ContainerRepository(database: appDatabase) }

    var body: some View {
        Group {
            if let room {
                containerList(for: room)
            } else if roomLoaded {
                NotInCatalogView(kind: "room")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(room?.name ?? "Room")
        .navigationBarTitleDisplayMode(.large)
        .themedScreen()
        .toolbar {
            if room != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Edit Room", systemImage: "pencil") {
                        isEditingRoom = true
                    }
                    Button("Add Container", systemImage: "plus") {
                        isAddingContainer = true
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingContainer) {
            ContainerEditorView(container: nil, defaultRoomID: roomID) { container, created in
                labelNudge.containerSaved(
                    id: container.id, name: container.name, created: created)
            }
        }
        .sheet(isPresented: $isEditingRoom) {
            if let room {
                RoomEditorView(room: room)
            }
        }
        // The offer survives under the sheet and clears on dismiss — the
        // nudge served its purpose either way, and clearing it *while*
        // presenting would race the presentation (DL59's lesson).
        .sheet(item: $printingOffer, onDismiss: { labelNudge.dismiss() }) { offer in
            LabelSheetView(preselectedContainerIDs: [offer.containerID])
        }
        .task {
            do {
                for try await value in roomRepository.observeRoom(id: roomID) {
                    let hadRoom = room != nil
                    room = value
                    roomLoaded = true
                    if hadRoom && value == nil {
                        // Deleted while on screen (e.g. via Edit) — leave.
                        dismiss()
                    }
                }
            } catch {
                Log.data.error("Room observation failed: \(String(describing: error))")
            }
        }
        .task {
            do {
                for try await value in containerRepository.observeContainers(inRoom: roomID) {
                    containers = value
                }
            } catch {
                Log.data.error("Container list observation failed: \(String(describing: error))")
            }
        }
    }

    private func containerList(for room: Room) -> some View {
        Group {
            if containers.isEmpty {
                ContentUnavailableView {
                    if let fenColors = themeStore.theme.fenColors {
                        VStack(spacing: Tokens.spacingM) {
                            FenFigure(
                                colors: fenColors,
                                style: themeStore.theme.fenStyle,
                                glow: themeStore.theme.fenGlow,
                                earPerkTrigger: fenPerkTrigger)
                                .frame(height: 88)
                            Text("No Containers")
                        }
                    } else {
                        Label("No Containers", systemImage: "shippingbox")
                    }
                } description: {
                    Text("Add the bins, drawers, and shelves that live in \(room.name).")
                } actions: {
                    Button("Add Container") {
                        // Ear-perk where Fen is on screen (Cozy/Pop! —
                        // the Arcade sprite doesn't perk).
                        switch themeStore.theme.fenPresence {
                        case .lightTouch, .medium: fenPerkTrigger += 1
                        case .none, .fullSprite: break
                        }
                        isAddingContainer = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    // U3: one inline offer after a creation — never a modal,
                    // never persisted, gone on dismiss or once printing opens.
                    if let offer = labelNudge.offer {
                        Section {
                            LabelNudgeRow(
                                offer: offer,
                                onPrint: { printingOffer = offer },
                                onDismiss: { labelNudge.dismiss() })
                        }
                        .themedRow()
                    }
                    Section {
                        ForEach(containers) { entry in
                            NavigationLink(value: Route.container(id: entry.container.id)) {
                                ContainerRow(entry: entry)
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { containers[$0].container.id }
                            Task {
                                do {
                                    try await containerRepository.deleteContainers(ids: ids)
                                } catch {
                                    Log.data.error("Container delete failed: \(String(describing: error))")
                                }
                            }
                        }
                        .themedRow()
                    }
                }
                // U12: the nudge's arrival/departure rides the theme's
                // settle spring; one plain fade under Reduce Motion.
                .animation(
                    themeStore.theme.motion.animation(.settle, reduceMotion: reduceMotion),
                    value: labelNudge.offer)
            }
        }
    }
}

/// U3's inline offer row: text, a Print button into the label-sheet flow
/// with the new container preselected, and an explicit dismiss. Borderless
/// button styles keep the three targets independent inside the row.
private struct LabelNudgeRow: View {
    let offer: LabelNudgeState.Offer
    let onPrint: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Tokens.spacingM) {
            Image(systemName: "printer")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("Print a label for this bin?")
                    .font(.subheadline.weight(.medium))
                Text(offer.containerName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Print") { onPrint() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
    }
}

private struct ContainerRow: View {
    let entry: ContainerListEntry

    var body: some View {
        HStack(spacing: Tokens.spacingM) {
            if let coverRef = entry.coverPhotoAssetRef {
                // The user-designated cover item's photo (P10); a missing file
                // shows the placeholder (P13). No cover → the standard icon.
                PhotoThumbnailView(ref: coverRef, size: 40)
            } else {
                Image(systemName: "shippingbox")
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading) {
                Text(entry.container.name)
                Text("^[\(entry.itemCount) item](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.container.labelSlot != nil {
                Image(systemName: "qrcode")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Label printed")
            }
        }
    }
}

/// Friendly state for a scanned/linked UUID that isn't in the catalog.
struct NotInCatalogView: View {
    let kind: String

    var body: some View {
        ContentUnavailableView {
            Label("Not in Your Catalog", systemImage: "qrcode")
        } description: {
            Text("This label isn't linked to a \(kind) in your catalog. It may have been deleted, or the label belongs to something else.")
        }
    }
}
