import SwiftUI

/// Create/edit sheet for a category: name and color token.
struct CategoryEditorView: View {
    /// nil creates a new category.
    let category: Category?

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var colorToken: String
    @State private var saveError: String?

    private var repository: CategoryRepository { CategoryRepository(database: appDatabase) }

    init(category: Category?) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _colorToken = State(initialValue: category?.colorToken ?? "gray")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Category name", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Color") {
                    ColorTokenPicker(selection: $colorToken)
                }
            }
            .navigationTitle(category == nil ? "New Category" : "Edit Category")
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
            .saveErrorAlert($saveError)
        }
        // M6.2: form-sheet sizing on iPad (see RoomEditorView).
        .presentationSizing(.form)
    }

    private func save() {
        let name = trimmedName
        let colorToken = colorToken
        let existing = category
        Task {
            do {
                if var category = existing {
                    category.name = name
                    category.colorToken = colorToken
                    try await repository.updateCategory(category)
                } else {
                    try await repository.createCategory(name: name, colorToken: colorToken)
                }
                Haptics.saveSoftImpact() // T10 — every theme
                dismiss()
            } catch {
                Log.data.error("Category save failed: \(String(describing: error))")
                saveError = error.localizedDescription
            }
        }
    }
}

private struct ColorTokenPicker: View {
    @Binding var selection: String

    private let columns = [GridItem(.adaptive(minimum: 44))]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Tokens.spacingS) {
            ForEach(Tokens.categoryColorTokens, id: \.self) { token in
                Button {
                    selection = token
                } label: {
                    Circle()
                        .fill(Tokens.categoryColor(for: token))
                        .frame(width: 32, height: 32)
                        .overlay {
                            if token == selection {
                                Image(systemName: "checkmark")
                                    .font(.footnote.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(token)
                .accessibilityAddTraits(token == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, Tokens.spacingS)
    }
}
