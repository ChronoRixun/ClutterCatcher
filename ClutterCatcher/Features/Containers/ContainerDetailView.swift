import SwiftUI
import UIKit

/// One container: what's inside, plus its QR label. This is where a scanned
/// label lands — including the friendly not-found state for unknown UUIDs.
struct ContainerDetailView: View {
    let containerID: String

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss

    @State private var detail: ContainerDetail?
    @State private var detailLoaded = false
    @State private var editingItem: Item?
    @State private var isAddingItem = false
    @State private var isEditingContainer = false
    @State private var isPrintingLabel = false
    @State private var isConfirmingDelete = false

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
        .navigationTitle(detail?.container.name ?? "Container")
        .navigationBarTitleDisplayMode(.large)
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
        .task {
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
        List {
            Section {
                LabeledContent("Room", value: detail.roomName)
                if let notes = detail.container.notes {
                    Text(notes)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Items") {
                if detail.items.isEmpty {
                    Text("Nothing catalogued in here yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.items) { entry in
                        Button {
                            editingItem = entry.item
                        } label: {
                            ItemRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { detail.items[$0].item.id }
                        Task {
                            do {
                                try await itemRepository.deleteItems(ids: ids)
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
        }
    }
}

private struct ItemRow: View {
    let entry: ItemListEntry

    var body: some View {
        HStack(spacing: Tokens.spacingM) {
            VStack(alignment: .leading) {
                Text(entry.item.name)
                if let categoryName = entry.categoryName {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Tokens.categoryColor(for: entry.categoryColorToken ?? "gray"))
                            .frame(width: 8, height: 8)
                        Text(categoryName)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
