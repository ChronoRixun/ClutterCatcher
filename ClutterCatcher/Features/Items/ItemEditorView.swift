import SwiftUI

/// Create/edit sheet for an item: name, quantity, category, notes.
struct ItemEditorView: View {
    /// nil creates a new item in `containerID`.
    let item: Item?
    let containerID: String

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var quantity: Int
    @State private var notes: String
    @State private var categoryID: String?
    @State private var categories: [Category] = []
    @State private var isConfirmingDelete = false
    @State private var saveError: String?

    private var itemRepository: ItemRepository { ItemRepository(database: appDatabase) }
    private var categoryRepository: CategoryRepository { CategoryRepository(database: appDatabase) }

    init(item: Item?, containerID: String) {
        self.item = item
        self.containerID = containerID
        _name = State(initialValue: item?.name ?? "")
        _quantity = State(initialValue: item?.quantity ?? 1)
        _notes = State(initialValue: item?.notes ?? "")
        _categoryID = State(initialValue: item?.categoryId)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item name", text: $name)
                        .textInputAutocapitalization(.words)
                    Stepper(value: $quantity, in: 1...999) {
                        LabeledContent("Quantity", value: "\(quantity)")
                    }
                }
                Section("Category") {
                    Picker("Category", selection: $categoryID) {
                        Text("None").tag(String?.none)
                        ForEach(categories) { category in
                            HStack {
                                Circle()
                                    .fill(Tokens.categoryColor(for: category.colorToken))
                                    .frame(width: 10, height: 10)
                                Text(category.name)
                            }
                            .tag(String?.some(category.id))
                        }
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                if item != nil {
                    Section {
                        Button("Delete Item", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "New Item" : "Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .confirmationDialog(
                "Delete this item?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Item", role: .destructive) {
                    guard let id = item?.id else { return }
                    Task {
                        do {
                            try await itemRepository.deleteItems(ids: [id])
                            dismiss()
                        } catch {
                            Log.data.error("Item delete failed: \(String(describing: error))")
                            saveError = error.localizedDescription
                        }
                    }
                }
            }
            .saveErrorAlert($saveError)
            .task {
                do {
                    categories = try await categoryRepository.allCategories()
                } catch {
                    Log.data.error("Category fetch for picker failed: \(String(describing: error))")
                }
            }
        }
    }

    private func save() {
        let name = trimmedName
        let quantity = quantity
        let notes = notes
        let categoryID = categoryID
        let existing = item
        Task {
            do {
                if var item = existing {
                    item.name = name
                    item.quantity = quantity
                    item.notes = notes
                    item.categoryId = categoryID
                    try await itemRepository.updateItem(item)
                } else {
                    try await itemRepository.createItem(
                        containerID: containerID,
                        name: name,
                        quantity: quantity,
                        notes: notes,
                        categoryID: categoryID)
                }
                dismiss()
            } catch {
                Log.data.error("Item save failed: \(String(describing: error))")
                saveError = error.localizedDescription
            }
        }
    }
}
