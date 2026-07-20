import SwiftUI

/// Create/edit sheet for a container: name, room, notes.
struct ContainerEditorView: View {
    /// nil creates a new container.
    let container: Container?
    let defaultRoomID: String
    /// Reports every successful save with whether it was a creation — the
    /// U3 label nudge keys off exactly that distinction.
    let onSaved: ((Container, _ created: Bool) -> Void)?

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var roomID: String
    @State private var notes: String
    @State private var rooms: [Room] = []
    @State private var saveError: String?

    private var containerRepository: ContainerRepository { ContainerRepository(database: appDatabase) }
    private var roomRepository: RoomRepository { RoomRepository(database: appDatabase) }

    init(
        container: Container?, defaultRoomID: String,
        onSaved: ((Container, _ created: Bool) -> Void)? = nil
    ) {
        self.container = container
        self.defaultRoomID = defaultRoomID
        self.onSaved = onSaved
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
            .saveErrorAlert($saveError)
            .task {
                do {
                    rooms = try await roomRepository.allRooms()
                } catch {
                    Log.data.error("Room fetch for picker failed: \(String(describing: error))")
                }
            }
        }
        // M6.2: form-sheet sizing on iPad (see RoomEditorView).
        .presentationSizing(.form)
    }

    private func save() {
        let name = trimmedName
        let roomID = roomID
        let notes = notes
        let existing = container
        Task {
            do {
                let saved: Container
                let created: Bool
                if var container = existing {
                    container.name = name
                    container.roomId = roomID
                    container.notes = notes
                    try await containerRepository.updateContainer(container)
                    saved = container
                    created = false
                } else {
                    saved = try await containerRepository.createContainer(
                        roomID: roomID, name: name, notes: notes)
                    created = true
                }
                Haptics.saveSoftImpact() // T10 — every theme
                onSaved?(saved, created)
                dismiss()
            } catch {
                Log.data.error("Container save failed: \(String(describing: error))")
                saveError = error.localizedDescription
            }
        }
    }
}
