import SwiftUI

/// Create/edit sheet for a room: name and icon.
struct RoomEditorView: View {
    /// nil creates a new room.
    let room: Room?

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var icon: String

    private var repository: RoomRepository { RoomRepository(database: appDatabase) }

    init(room: Room?) {
        self.room = room
        _name = State(initialValue: room?.name ?? "")
        _icon = State(initialValue: room?.icon ?? Tokens.defaultRoomIcon)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Room name", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Icon") {
                    IconPicker(selection: $icon)
                }
            }
            .navigationTitle(room == nil ? "New Room" : "Edit Room")
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
        }
    }

    private func save() {
        let name = trimmedName
        let icon = icon
        let existing = room
        Task {
            do {
                if var room = existing {
                    room.name = name
                    room.icon = icon
                    try await repository.updateRoom(room)
                } else {
                    try await repository.createRoom(name: name, icon: icon)
                }
                dismiss()
            } catch {
                Log.data.error("Room save failed: \(error)")
            }
        }
    }
}

/// A grid of SF Symbol choices from the token sheet.
struct IconPicker: View {
    @Binding var selection: String

    private let columns = [GridItem(.adaptive(minimum: 44))]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Tokens.spacingS) {
            ForEach(Tokens.roomIcons, id: \.self) { symbol in
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .foregroundStyle(symbol == selection ? Color.white : Color.accentColor)
                        .background(
                            symbol == selection ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: Tokens.cornerRadius - 4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
                .accessibilityAddTraits(symbol == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, Tokens.spacingS)
    }
}
