import SwiftUI

/// Local search across the whole catalog: rooms, containers, items, categories.
struct SearchView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(ThemeStore.self) private var themeStore

    @State private var query = ""
    @State private var results = SearchResults()

    private var repository: SearchRepository { SearchRepository(database: appDatabase) }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Group {
                if trimmedQuery.isEmpty {
                    ContentUnavailableView {
                        if let fenColors = themeStore.theme.fenColors {
                            VStack(spacing: Tokens.spacingM) {
                                FenFigure(
                                    colors: fenColors,
                                    style: themeStore.theme.fenStyle,
                                    glow: themeStore.theme.fenGlow)
                                    .frame(height: 88)
                                Text("Find Anything")
                            }
                        } else {
                            Label("Find Anything", systemImage: "magnifyingglass")
                        }
                    } description: {
                        Text("Search your rooms, containers, items, and categories — \"where are the Christmas lights?\"")
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                } else {
                    resultsList
                }
            }
            .readableContentWidth() // M6.2
            .navigationTitle("Search")
            .themedScreen()
            .catalogDestinations()
        }
        .searchable(text: $query, prompt: "Rooms, containers, items…")
        .task(id: trimmedQuery) {
            guard !trimmedQuery.isEmpty else {
                results = SearchResults()
                return
            }
            // Debounce: each keystroke restarts this task, so the sleep
            // coalesces bursts of typing into one observation.
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            do {
                for try await value in repository.observeResults(matching: trimmedQuery) {
                    results = value
                }
            } catch {
                Log.data.error("Search observation failed: \(String(describing: error))")
            }
        }
    }

    private var resultsList: some View {
        List {
            if !results.rooms.isEmpty {
                Section("Rooms") {
                    ForEach(results.rooms) { room in
                        NavigationLink(value: Route.room(id: room.id)) {
                            Label(room.name, systemImage: room.icon ?? Tokens.defaultRoomIcon)
                        }
                    }
                }
                .themedRow()
            }
            if !results.containers.isEmpty {
                Section("Containers") {
                    ForEach(results.containers) { candidate in
                        NavigationLink(value: Route.container(id: candidate.container.id)) {
                            VStack(alignment: .leading) {
                                Text(candidate.container.name)
                                Text(candidate.roomName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .themedRow()
            }
            if !results.items.isEmpty {
                Section("Items") {
                    ForEach(results.items) { hit in
                        // U14: land on the container scrolled to the match.
                        NavigationLink(value: Route.container(
                            id: hit.item.containerId, highlightItemID: hit.item.id)) {
                            HStack(spacing: Tokens.spacingM) {
                                if let ref = hit.item.photoAssetRef {
                                    PhotoThumbnailView(ref: ref, size: 40)
                                }
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(hit.item.name)
                                        if hit.item.quantity > 1 {
                                            Text("×\(hit.item.quantity)")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text("\(hit.containerName) · \(hit.roomName)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .themedRow()
            }
            if !results.categories.isEmpty {
                Section("Categories") {
                    // U13: category results finally go somewhere — the
                    // browse view, not a dead row.
                    ForEach(results.categories) { category in
                        NavigationLink(value: Route.category(id: category.id)) {
                            HStack(spacing: Tokens.spacingM) {
                                Circle()
                                    .fill(Tokens.categoryColor(for: category.colorToken))
                                    .frame(width: 12, height: 12)
                                Text(category.name)
                            }
                        }
                    }
                }
                .themedRow()
            }
        }
    }
}
