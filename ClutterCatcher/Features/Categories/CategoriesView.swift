import SwiftUI

/// All categories with their item counts. Presented as a sheet from Rooms home.
struct CategoriesView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [CategoryListEntry] = []
    @State private var entriesLoaded = false
    @State private var editingCategory: Category?
    @State private var isAddingCategory = false

    private var repository: CategoryRepository { CategoryRepository(database: appDatabase) }

    var body: some View {
        Group {
            if !entriesLoaded {
                ProgressView()
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Categories", systemImage: "tag")
                } description: {
                    Text("Categories cut across rooms — Tools, Seasonal, Keepsakes — so you can find things by kind.")
                } actions: {
                    Button("Add Category") { isAddingCategory = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(entries) { entry in
                        Button {
                            editingCategory = entry.category
                        } label: {
                            HStack(spacing: Tokens.spacingM) {
                                Circle()
                                    .fill(Tokens.categoryColor(for: entry.category.colorToken))
                                    .frame(width: 14, height: 14)
                                Text(entry.category.name)
                                Spacer()
                                Text("^[\(entry.itemCount) item](inflect: true)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { entries[$0].category.id }
                        Task {
                            do {
                                try await repository.deleteCategories(ids: ids)
                            } catch {
                                Log.data.error("Category delete failed: \(String(describing: error))")
                            }
                        }
                    }
                    .themedRow()
                }
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add Category", systemImage: "plus") {
                    isAddingCategory = true
                }
            }
        }
        .sheet(isPresented: $isAddingCategory) {
            CategoryEditorView(category: nil)
        }
        .sheet(item: $editingCategory) { category in
            CategoryEditorView(category: category)
        }
        .task {
            do {
                for try await value in repository.observeCategoryList() {
                    entries = value
                    entriesLoaded = true
                }
            } catch {
                Log.data.error("Category list observation failed: \(String(describing: error))")
            }
        }
    }
}
