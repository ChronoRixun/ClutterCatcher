import SwiftUI

/// One room: its containers, with item counts.
struct RoomDetailView: View {
    let roomID: String

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var themeStore

    @State private var room: Room?
    @State private var roomLoaded = false
    @State private var containers: [ContainerListEntry] = []
    @State private var isAddingContainer = false
    @State private var isEditingRoom = false

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
            ContainerEditorView(container: nil, defaultRoomID: roomID)
        }
        .sheet(isPresented: $isEditingRoom) {
            if let room {
                RoomEditorView(room: room)
            }
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
                            FenFigure(colors: fenColors)
                                .frame(height: 88)
                            Text("No Containers")
                        }
                    } else {
                        Label("No Containers", systemImage: "shippingbox")
                    }
                } description: {
                    Text("Add the bins, drawers, and shelves that live in \(room.name).")
                } actions: {
                    Button("Add Container") { isAddingContainer = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
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
