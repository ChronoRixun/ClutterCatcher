import SwiftUI

/// Everything carrying one category, grouped room → container (M7b, U13) —
/// the findability payoff categories never had: tapping Seasonal shows
/// everything Seasonal, across rooms. Rows navigate to their container with
/// the item emphasized (U14's highlight route). Reached from CategoriesView,
/// search's category results, and `Route.category`.
struct CategoryBrowseView: View {
    let categoryID: String

    @Environment(\.appDatabase) private var appDatabase
    @Environment(ThemeStore.self) private var themeStore

    @State private var browse: CategoryBrowse?
    @State private var browseLoaded = false

    private var repository: CategoryRepository { CategoryRepository(database: appDatabase) }

    var body: some View {
        Group {
            if let browse {
                if browse.rooms.isEmpty {
                    emptyState(browse)
                } else {
                    contentList(browse)
                }
            } else if browseLoaded {
                // A stale link (category deleted): kinder than a blank list.
                ContentUnavailableView {
                    Label("Category Not Found", systemImage: "tag.slash")
                } description: {
                    Text("This category is no longer in your catalog.")
                }
            } else {
                ProgressView()
            }
        }
        .readableContentWidth() // M6.2
        .navigationTitle(browse?.category.name ?? "Category")
        .navigationBarTitleDisplayMode(.large)
        .themedScreen()
        // Keyed to the category — same stack-replace identity rule as the
        // other catalog destinations (see catalogDestinations note).
        .task(id: categoryID) {
            if browseLoaded {
                browse = nil
                browseLoaded = false
            }
            do {
                for try await value in repository.observeBrowse(categoryID: categoryID) {
                    browse = value
                    browseLoaded = true
                }
            } catch {
                Log.data.error("Category browse observation failed: \(String(describing: error))")
            }
        }
    }

    // U12: no Fen on new surfaces — the presence dial is unchanged.
    private func emptyState(_ browse: CategoryBrowse) -> some View {
        ContentUnavailableView {
            Label("Nothing \(browse.category.name) Yet", systemImage: "tag")
        } description: {
            Text("Give items this category and they'll gather here, across every room.")
        }
    }

    private func contentList(_ browse: CategoryBrowse) -> some View {
        List {
            Section {
                HStack(spacing: Tokens.spacingS) {
                    ThemedChip(
                        text: browse.itemCount == 1 ? "1 item" : "\(browse.itemCount) items",
                        base: Tokens.categoryColor(for: browse.category.colorToken))
                    ThemedChip(
                        text: browse.rooms.count == 1 ? "1 room" : "\(browse.rooms.count) rooms",
                        base: themeStore.theme.accent2)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: Tokens.spacingS, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }

            ForEach(browse.rooms) { room in
                Section(room.name) {
                    ForEach(room.containers) { container in
                        ForEach(container.items) { item in
                            // U14: land on the container scrolled to this item.
                            NavigationLink(value: Route.container(
                                id: container.id, highlightItemID: item.id)) {
                                BrowseItemRow(item: item, containerName: container.name)
                            }
                        }
                    }
                }
                .themedRow()
            }
        }
    }
}

/// An item row in the browse list: the room is the section header, so the
/// container carries the "where" line — consecutive rows sharing it read as
/// the room → container grouping.
private struct BrowseItemRow: View {
    let item: Item
    let containerName: String

    var body: some View {
        HStack(spacing: Tokens.spacingM) {
            if let ref = item.photoAssetRef {
                PhotoThumbnailView(ref: ref, size: 40)
            }
            VStack(alignment: .leading) {
                HStack {
                    Text(item.name)
                    if item.quantity > 1 {
                        Text("×\(item.quantity)")
                            .foregroundStyle(.secondary)
                    }
                }
                Text(containerName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
