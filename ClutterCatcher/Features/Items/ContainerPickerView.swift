import SwiftUI

/// U2: where an item lives — the full catalog grouped by room, current
/// container checked. Pushed inside the item editor's stack; choosing pops
/// back with the selection *staged*, committed on Save like every other
/// editor field.
struct ContainerPickerView: View {
    let candidates: [ContainerCandidate]
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(groupedByRoom, id: \.roomID) { group in
                Section(group.roomName) {
                    ForEach(group.candidates) { candidate in
                        Button {
                            selection = candidate.id
                            dismiss()
                        } label: {
                            HStack {
                                Text(candidate.container.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if candidate.id == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityLabel("Current container")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(candidate.id == selection ? .isSelected : [])
                    }
                }
            }
        }
        .navigationTitle("Container")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Candidates arrive room-ordered (room sort order, then name), so one
    /// pass groups them; keyed by room id — names may repeat.
    private var groupedByRoom: [(roomID: String, roomName: String, candidates: [ContainerCandidate])] {
        var groups: [(roomID: String, roomName: String, candidates: [ContainerCandidate])] = []
        for candidate in candidates {
            if groups.last?.roomID == candidate.container.roomId {
                groups[groups.count - 1].candidates.append(candidate)
            } else {
                groups.append((candidate.container.roomId, candidate.roomName, [candidate]))
            }
        }
        return groups
    }
}
