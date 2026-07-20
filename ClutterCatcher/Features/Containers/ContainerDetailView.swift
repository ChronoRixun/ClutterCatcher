import SwiftUI
import UIKit

/// One container: what's inside, plus its QR label. This is where a scanned
/// label lands — including the friendly not-found state for unknown UUIDs.
struct ContainerDetailView: View {
    let containerID: String
    /// U14: the matched item to scroll to and briefly emphasize on arrival —
    /// search results, Spotlight taps, and the Find intent set it; plain
    /// navigation leaves it nil.
    var highlightItemID: String? = nil

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.photoStore) private var photoStore
    @Environment(\.syncCoordinator) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var detail: ContainerDetail?
    @State private var detailLoaded = false
    @State private var editingItem: Item?
    @State private var isAddingItem = false
    @State private var isEditingContainer = false
    @State private var isPrintingLabel = false
    @State private var isConfirmingDelete = false
    // U14 highlight state lives on the screen, not the row — container rows
    // get recreated around list updates (the DL62 lesson), and a row-local
    // flag would die mid-emphasis.
    @State private var highlightedItemID: String?

    private var containerRepository: ContainerRepository { ContainerRepository(database: appDatabase) }
    private var itemRepository: ItemRepository { ItemRepository(database: appDatabase) }

    var body: some View {
        Group {
            if let detail {
                contentList(detail)
            } else if detailLoaded {
                NotInCatalogView(kind: "container")
            } else {
                ProgressView()
            }
        }
        .readableContentWidth() // M6.2
        .navigationTitle(detail?.container.name ?? "Container")
        .navigationBarTitleDisplayMode(.large)
        .themedScreen()
        .toolbar {
            if detail != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit Container", systemImage: "pencil") {
                            isEditingContainer = true
                        }
                        Button("Print Label…", systemImage: "printer") {
                            isPrintingLabel = true
                        }
                        Divider()
                        Button("Delete Container", systemImage: "trash", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Item", systemImage: "plus") {
                        isAddingItem = true
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingItem) {
            ItemEditorView(item: nil, containerID: containerID)
        }
        .sheet(item: $editingItem) { item in
            ItemEditorView(item: item, containerID: containerID)
        }
        .sheet(isPresented: $isEditingContainer) {
            if let detail {
                ContainerEditorView(container: detail.container, defaultRoomID: detail.container.roomId)
            }
        }
        .sheet(isPresented: $isPrintingLabel) {
            LabelSheetView(preselectedContainerIDs: [containerID])
        }
        .confirmationDialog(
            "Delete this container and everything in it?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Container", role: .destructive) {
                Task {
                    do {
                        // The observation's nil emission pops this screen.
                        try await containerRepository.deleteContainers(ids: [containerID])
                    } catch {
                        Log.data.error("Container delete failed: \(String(describing: error))")
                    }
                }
            }
        }
        // Keyed to the container: a stack-replace that swaps this screen's
        // route re-runs the observation for the new container instead of
        // silently keeping the old one's (see catalogDestinations note).
        .task(id: containerID) {
            if detailLoaded {
                detail = nil
                detailLoaded = false
                highlightedItemID = nil
            }
            do {
                for try await value in containerRepository.observeDetail(containerID: containerID) {
                    let hadDetail = detail != nil
                    detail = value
                    detailLoaded = true
                    if hadDetail && value == nil {
                        // Deleted while on screen — leave rather than
                        // flipping into the not-found state.
                        dismiss()
                    }
                }
            } catch {
                Log.data.error("Container detail observation failed: \(String(describing: error))")
            }
        }
    }

    private func contentList(_ detail: ContainerDetail) -> some View {
        ScrollViewReader { proxy in
            innerList(detail)
                // Runs when this list first appears with content, and again
                // if a same-container stack-replace changes only the
                // highlight target.
                .task(id: highlightItemID) {
                    await runHighlightIfNeeded(proxy: proxy, detail: detail)
                }
        }
    }

    private func innerList(_ detail: ContainerDetail) -> some View {
        List {
            // §4: room and item count as chips under the title.
            Section {
                HStack(spacing: Tokens.spacingS) {
                    ThemedChip(text: detail.roomName, base: themeStore.theme.accent)
                    ThemedChip(
                        text: detail.items.count == 1 ? "1 item" : "\(detail.items.count) items",
                        base: themeStore.theme.accent2)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: Tokens.spacingS, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }

            if detail.container.notes != nil || detail.createdByName != nil {
                Section {
                    if let notes = detail.container.notes {
                        Text(notes)
                            .foregroundStyle(.secondary)
                    }
                    if let createdByName = detail.createdByName {
                        Text("Added by \(createdByName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()
            }

            Section("Inside") {
                if detail.items.isEmpty {
                    Text("Nothing catalogued in here yet.")
                        .foregroundStyle(.secondary)
                        .themedRow()
                } else {
                    ForEach(detail.items) { entry in
                        Button {
                            editingItem = entry.item
                        } label: {
                            ItemRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        // U14: the row backgrounds in this section resolve
                        // through one helper so the matched row's emphasis
                        // can override the themed surface deterministically.
                        .listRowBackground(insideRowBackground(entry))
                        // §6 save reward: Pop!'s saved row drops in with a
                        // squash-settle; everyone else keeps the standard
                        // row insertion under their own settle spring.
                        .transition(
                            themeStore.theme.motion.saveReward(reduceMotion: reduceMotion)
                                == .squashSettle ? .dropInSquash : .opacity)
                    }
                    .onDelete { offsets in
                        let deleted = offsets.map { detail.items[$0].item }
                        let ids = deleted.map(\.id)
                        let refs = deleted.compactMap(\.photoAssetRef)
                        Task {
                            do {
                                try await itemRepository.deleteItems(ids: ids)
                                // Local photo cache cleanup for the deleted
                                // items (§4). CloudKit deletion is implicit.
                                for ref in refs { try? photoStore.delete(id: ref) }
                            } catch {
                                Log.data.error("Item delete failed: \(String(describing: error))")
                            }
                        }
                    }
                }
            }

            Section("QR Label") {
                QRLabelPreview(container: detail.container)
            }
            .themedRow()
        }
        .refreshable {
            // P13: pull-to-refresh nudges a fetch so missing photos download.
            await coordinator?.requestPhotoRefetch()
        }
        // Item-list changes settle with the theme's spring; Classic (settle
        // nil) keeps its pre-M4b list behavior — nil disables animation.
        .animation(itemListAnimation, value: detail.items)
    }

    private var itemListAnimation: Animation? {
        guard themeStore.theme.motion.settle != nil else { return nil }
        return themeStore.theme.motion.animation(.settle, reduceMotion: reduceMotion)
    }

    // MARK: U14 — matched-item highlight

    /// The Inside section's row surface: the matched row wears the theme's
    /// accent wash while emphasized; everything else keeps the themedRow()
    /// treatment (Classic's nil = the untouched system surface).
    private func insideRowBackground(_ entry: ItemListEntry) -> Color? {
        if entry.id == highlightedItemID {
            return themeStore.theme.accent.opacity(0.25)
        }
        return themeStore.theme.isClassic ? nil : themeStore.theme.surface
    }

    /// One shot per presentation of a target: scroll to the matched row,
    /// hold the emphasis briefly, then let it settle away on the theme's
    /// spring (the plain fade under Reduce Motion — the existing DL60 seam).
    @MainActor
    private func runHighlightIfNeeded(proxy: ScrollViewProxy, detail: ContainerDetail) async {
        guard let target = highlightItemID,
              detail.items.contains(where: { $0.id == target }) else { return }
        highlightedItemID = target
        let settle = themeStore.theme.motion.animation(.settle, reduceMotion: reduceMotion)
        // Let the freshly pushed list finish layout before jumping. A
        // cancelled task (screen left mid-emphasis) stops instead of
        // fast-forwarding through the choreography.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        withAnimation(settle) {
            proxy.scrollTo(target, anchor: .center)
        }
        try? await Task.sleep(for: .milliseconds(1800))
        guard !Task.isCancelled else { return }
        withAnimation(settle) {
            highlightedItemID = nil
        }
    }
}

private struct ItemRow: View {
    let entry: ItemListEntry

    var body: some View {
        HStack(spacing: Tokens.spacingM) {
            if let ref = entry.item.photoAssetRef {
                // Leading thumbnail when present; placeholder when the ref is
                // set but the file is still downloading/wiped (P13). Rows
                // without a photo keep their original layout.
                PhotoThumbnailView(ref: ref, size: 44)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.name)
                if let categoryName = entry.categoryName {
                    // §4/T12: category as a tinted capsule chip, derived from
                    // the category's own color so it works in every palette.
                    ThemedChip(
                        text: categoryName,
                        base: Tokens.categoryColor(for: entry.categoryColorToken ?? "gray"),
                        compact: true)
                }
            }
            Spacer()
            if entry.item.quantity > 1 {
                Text("×\(entry.item.quantity)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The container's QR code as it will appear on a printed label.
private struct QRLabelPreview: View {
    let container: Container

    private var payload: QRPayload? {
        guard let uuid = UUID(uuidString: container.id) else { return nil }
        return .container(uuid)
    }

    var body: some View {
        if let payload {
            HStack(spacing: Tokens.spacingL) {
                if let image = QRCodeGenerator.image(for: payload) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .accessibilityLabel("QR code for \(container.name)")
                }
                VStack(alignment: .leading, spacing: Tokens.spacingS) {
                    if let slot = container.labelSlot {
                        Text("Label #\(slot)")
                            .font(.subheadline)
                    } else {
                        Text("Not printed yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(payload.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, Tokens.spacingS)
        }
    }
}
