import SwiftUI

/// Home: every room in the house, with container counts. Also the entry point
/// for label printing and the Categories screen.
struct RoomsHomeView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(Router.self) private var router

    @State private var entries: [RoomListEntry] = []
    @State private var entriesLoaded = false
    @State private var isAddingRoom = false
    @State private var isShowingLabelSheet = false
    @State private var isShowingCategories = false
    /// Rooms awaiting delete confirmation — deleting a room cascades to all
    /// of its containers and items, so a bare swipe must not be enough.
    @State private var pendingDeletion: [RoomListEntry] = []

    private var repository: RoomRepository { RoomRepository(database: appDatabase) }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.catalogPath) {
            Group {
                if !entriesLoaded {
                    ProgressView()
                } else if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Rooms Yet", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Add the rooms of your home, then fill them with containers.")
                    } actions: {
                        Button("Add Room") { isAddingRoom = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    roomList
                }
            }
            .navigationTitle("Rooms")
            .catalogDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Print Labels…", systemImage: "printer") {
                            isShowingLabelSheet = true
                        }
                        Button("Categories", systemImage: "tag") {
                            isShowingCategories = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    Button("Add Room", systemImage: "plus") {
                        isAddingRoom = true
                    }
                }
            }
            .sheet(isPresented: $isAddingRoom) {
                RoomEditorView(room: nil)
            }
            .sheet(isPresented: $isShowingLabelSheet) {
                LabelSheetView()
            }
            .sheet(isPresented: $isShowingCategories) {
                NavigationStack { CategoriesView() }
            }
            .confirmationDialog(
                deletionTitle,
                isPresented: Binding(
                    get: { !pendingDeletion.isEmpty },
                    set: { if !$0 { pendingDeletion = [] } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let ids = pendingDeletion.map(\.room.id)
                    pendingDeletion = []
                    Task {
                        do {
                            try await repository.deleteRooms(ids: ids)
                        } catch {
                            Log.data.error("Room delete failed: \(String(describing: error))")
                        }
                    }
                }
            } message: {
                Text("Everything inside — containers and items — is deleted with it. This cannot be undone.")
            }
        }
        .onChange(of: router.catalogPath) {
            // A deep link (Camera-app scan) must never land invisibly behind
            // a modal; during normal in-app navigation these are false anyway.
            isAddingRoom = false
            isShowingLabelSheet = false
            isShowingCategories = false
        }
        .task {
            do {
                for try await value in repository.observeRoomList() {
                    entries = value
                    entriesLoaded = true
                }
            } catch {
                Log.data.error("Room list observation failed: \(String(describing: error))")
            }
        }
    }

    private var deletionTitle: String {
        if pendingDeletion.count == 1, let entry = pendingDeletion.first {
            "Delete “\(entry.room.name)”?"
        } else {
            "Delete \(pendingDeletion.count) rooms?"
        }
    }

    private var roomList: some View {
        List {
            ForEach(entries) { entry in
                NavigationLink(value: Route.room(id: entry.room.id)) {
                    RoomRow(entry: entry)
                }
            }
            .onMove { source, destination in
                var reordered = entries
                reordered.move(fromOffsets: source, toOffset: destination)
                entries = reordered
                let orderedIDs = reordered.map(\.room.id)
                Task {
                    do {
                        try await repository.reorderRooms(orderedIDs: orderedIDs)
                    } catch {
                        Log.data.error("Room reorder failed: \(String(describing: error))")
                    }
                }
            }
            .onDelete { offsets in
                pendingDeletion = offsets.map { entries[$0] }
            }
        }
    }
}

private struct RoomRow: View {
    let entry: RoomListEntry

    var body: some View {
        HStack(spacing: Tokens.spacingM) {
            Image(systemName: entry.room.icon ?? Tokens.defaultRoomIcon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Tokens.cornerRadius - 4))
            VStack(alignment: .leading) {
                Text(entry.room.name)
                Text("^[\(entry.containerCount) container](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
