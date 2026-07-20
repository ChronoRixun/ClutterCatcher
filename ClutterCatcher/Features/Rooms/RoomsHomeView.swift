import SwiftUI

/// §6 cross-cutting (M4b): the staggered spring-settle runs once per launch —
/// this flag is deliberately process-lived, not view-lived, so re-visiting
/// the tab never replays it.
@MainActor
private enum RoomsFirstLoad {
    static var hasStaggered = false
}

/// Home: every room in the house, with container counts. Also the entry point
/// for label printing and the Categories screen.
struct RoomsHomeView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(Router.self) private var router
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var entries: [RoomListEntry] = []
    @State private var entriesLoaded = false
    @State private var isAddingRoom = false
    @State private var isShowingLabelSheet = false
    @State private var isShowingCategories = false
    /// Fen's ear-perk on the empty state's primary button (§5 M4b —
    /// Cozy and Pop!).
    @State private var fenPerkTrigger = 0
    /// false only while this launch's one staggered load-in is pending;
    /// rows render hidden for a beat, then settle in with per-row delays.
    @State private var rowsArrived = true
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
                    // §4 empty-state refresh; Fen appears where the theme's
                    // presence dial says so (§5), blinking idly — Arcade as
                    // the pixel sprite (M4b).
                    ContentUnavailableView {
                        if let fenColors = themeStore.theme.fenColors {
                            VStack(spacing: Tokens.spacingM) {
                                FenFigure(
                                    colors: fenColors,
                                    style: themeStore.theme.fenStyle,
                                    glow: themeStore.theme.fenGlow,
                                    earPerkTrigger: fenPerkTrigger)
                                    .frame(height: 88)
                                Text("Let's give everything a home")
                            }
                        } else {
                            Label("Let's give everything a home", systemImage: "square.grid.2x2")
                        }
                    } description: {
                        Text("Add the rooms of your house, then fill them with bins, drawers, and shelves.")
                    } actions: {
                        Button("Add Your First Room") {
                            perkFenIfPresent()
                            isAddingRoom = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if horizontalSizeClass == .regular {
                    // M6.2: regular width trades the list for a grid of the
                    // T11 accent-cycle tiles; compact keeps the exact iPhone
                    // list (a 50/50 Split View pane is compact and gets it).
                    roomGrid
                } else {
                    roomList
                }
            }
            .navigationTitle("Rooms")
            .themedScreen()
            .catalogDestinations()
            .toolbar {
                // Edit (reorder/multi-delete) is a list affordance; the grid
                // deletes via each card's context menu instead.
                if horizontalSizeClass != .regular {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
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
                // U13: category rows push the browse view (and from there,
                // containers) inside the sheet's own stack.
                NavigationStack { CategoriesView().catalogDestinations() }
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
                    // The stagger decision rides in front of the first
                    // non-empty render (§6: first appearance per launch).
                    if !entriesLoaded, !value.isEmpty, !RoomsFirstLoad.hasStaggered {
                        RoomsFirstLoad.hasStaggered = true
                        rowsArrived = false
                    }
                    entries = value
                    entriesLoaded = true
                    if !rowsArrived {
                        Task { @MainActor in
                            // One beat hidden, then the delayed settles run.
                            try? await Task.sleep(for: .milliseconds(60))
                            rowsArrived = true
                        }
                    }
                }
            } catch {
                Log.data.error("Room list observation failed: \(String(describing: error))")
            }
        }
    }

    /// §5 M4b: ear-perk on primary-button press where Fen is on screen —
    /// Cozy (light touch) and Pop! (medium) only; the Arcade sprite doesn't
    /// perk, per the kickoff's theme list. FenFigure suppresses the
    /// animation under Reduce Motion.
    private func perkFenIfPresent() {
        switch themeStore.theme.fenPresence {
        case .lightTouch, .medium: fenPerkTrigger += 1
        case .none, .fullSprite: break
        }
    }

    private var deletionTitle: String {
        if pendingDeletion.count == 1, let entry = pendingDeletion.first {
            "Delete “\(entry.room.name)”?"
        } else {
            "Delete \(pendingDeletion.count) rooms?"
        }
    }

    /// §4 + U4: the line under the large title grows up with the catalog —
    /// aspiration until the first container exists, live counts after
    /// (RoomsSubtitle owns the threshold). Shared by the list and the grid.
    private var subtitleText: some View {
        Group {
            switch RoomsSubtitle.subtitle(
                roomCount: entries.count, containerCount: totalContainerCount) {
            case .aspirational:
                Text("Let's give everything a home — start by adding bins to a room.")
            case .counts(let rooms, let containers):
                Text("^[\(rooms) room](inflect: true) · ^[\(containers) container](inflect: true) · everything has a home")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var roomList: some View {
        List {
            Section {
                subtitleText
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: Tokens.spacingS, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    NavigationLink(value: Route.room(id: entry.room.id)) {
                        RoomRow(entry: entry)
                    }
                    // §6 cross-cutting: the once-per-launch staggered
                    // settle (~30 ms/row). Under Reduce Motion the offset
                    // and stagger vanish — one plain fade.
                    .opacity(rowsArrived ? 1 : 0)
                    .offset(y: rowsArrived || reduceMotion ? 0 : 10)
                    .animation(
                        themeStore.theme.motion.animation(.settle, reduceMotion: reduceMotion)
                            .delay(MotionPersonality.staggerDelay(
                                forIndex: index, reduceMotion: reduceMotion)),
                        value: rowsArrived)
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
                .themedRow()
            }
        }
    }

    /// M6.2: the regular-width Rooms home — the T11 accent-cycle tiles as an
    /// adaptive card grid. Column count is pure math (AdaptiveLayout, tested);
    /// delete rides each card's context menu into the same confirmation the
    /// list uses. Reorder stays a list (compact-width) affordance.
    private var roomGrid: some View {
        GeometryReader { proxy in
            let columnCount = AdaptiveLayout.roomGridColumnCount(
                forWidth: proxy.size.width - Tokens.spacingL * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.spacingL) {
                    subtitleText
                        .padding(.horizontal, Tokens.spacingS)
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: Tokens.spacingM),
                            count: columnCount),
                        spacing: Tokens.spacingM
                    ) {
                        ForEach(entries) { entry in
                            NavigationLink(value: Route.room(id: entry.room.id)) {
                                RoomCard(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete Room…", systemImage: "trash", role: .destructive) {
                                    pendingDeletion = [entry]
                                }
                            }
                        }
                    }
                }
                .padding(Tokens.spacingL)
            }
        }
    }

    private var totalContainerCount: Int {
        entries.reduce(0) { $0 + $1.containerCount }
    }
}

/// One room as a grid card (M6.2, regular width): the list row's icon tile
/// and counts on a themed surface. Classic uses the grouped-row color the
/// list would have painted — same information, roomier clothes.
private struct RoomCard: View {
    let entry: RoomListEntry

    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        let theme = themeStore.theme
        let tileColor = theme.cycleAccent(forSortOrder: entry.room.sortOrder)
        HStack(spacing: Tokens.spacingM) {
            Image(systemName: entry.room.displayIcon)
                .font(.title2)
                .foregroundStyle(tileColor)
                .frame(width: 44, height: 44)
                .background(tileColor.opacity(0.15), in: RoundedRectangle(cornerRadius: Tokens.cornerRadius - 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.room.name)
                    .font(.headline)
                    .lineLimit(1)
                if entry.containerCount == 0 {
                    Text("No bins yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("^[\(entry.containerCount) container](inflect: true)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Tokens.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.isClassic ? Color(.secondarySystemGroupedBackground) : theme.surface,
            in: RoundedRectangle(cornerRadius: Tokens.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: Tokens.cornerRadius))
        .accessibilityElement(children: .combine)
    }
}

private struct RoomRow: View {
    let entry: RoomListEntry

    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        // T11: the icon tile's tint comes from the theme's accent cycle,
        // keyed off the room's persisted sort position.
        let tileColor = themeStore.theme.cycleAccent(forSortOrder: entry.room.sortOrder)
        HStack(spacing: Tokens.spacingM) {
            Image(systemName: entry.room.displayIcon)
                .font(.title3)
                .foregroundStyle(tileColor)
                .frame(width: 36, height: 36)
                .background(tileColor.opacity(0.15), in: RoundedRectangle(cornerRadius: Tokens.cornerRadius - 4))
            VStack(alignment: .leading) {
                Text(entry.room.name)
                // U6: an empty room reads as an invitation, not dead weight —
                // gentler words, one hierarchy step dimmer. Hierarchical
                // styles derive from context, so this holds in all twelve
                // palettes (and Classic — a skeleton change, T8 precedent).
                if entry.containerCount == 0 {
                    Text("No bins yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("^[\(entry.containerCount) container](inflect: true)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
