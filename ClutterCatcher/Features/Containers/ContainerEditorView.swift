import SwiftUI

/// Create/edit sheet for a container: name, room, notes.
struct ContainerEditorView: View {
    /// nil creates a new container.
    let container: Container?
    let defaultRoomID: String

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var roomID: String
    @State private var notes: String
    @State private var rooms: [Room] = []

    private var containerRepository: ContainerRepository { ContainerRepository(database: appDatabase) }
    private var roomRepository: RoomRepository { RoomRepository(database: appDatabase) }

    init(container: Container?, defaultRoomID: String) {
        self.container = container
        self.defaultRoomID = defaultRoomID
        _name = State(initialValue: container?.name ?? "")
        _roomID = State(initialValue: container?.roomId ?? defaultRoomID)
        _notes = State(initialValue: container?.notes ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Container name", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Room") {
                    Picker("Room", selection: $roomID) {
                        ForEach(rooms) { room in
                            Text(room.name).tag(room.id)
                        }
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(container == nil ? "New Container" : "Edit Container")
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
            .task {
                do {
                    rooms = try await roomRepository.allRooms()
                } catch {
                    Log.data.error("Room fetch for picker failed: \(error)")
                }
            }
        }
    }

    private func save() {
        let name = trimmedName
        let roomID = roomID
        let notes = notes
        let existing = container
        Task {
            do {
                if var container = existing {
                    container.name = name
                    container.roomId = roomID
                    container.notes = notes
                    try await containerRepository.updateContainer(container)
                } else {
                    try await containerRepository.createContainer(
                        roomID: roomID, name: name, notes: notes)
                }
                dismiss()
            } catch {
                Log.data.error("Container save failed: \(error)")
            }
        }
    }
}
