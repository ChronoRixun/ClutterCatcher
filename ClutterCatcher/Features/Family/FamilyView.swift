import SwiftUI

/// Placeholder until zone sharing lands (M3). No CloudKit code yet by design
/// (plan §4, M0/M1).
struct FamilyView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Family Sharing Is Coming", systemImage: "person.3")
            } description: {
                Text("Soon the whole household will share one catalog — everyone sees the same bins, and edits show up on everybody's phone. Until then, ClutterCatcher keeps everything safely on this device.")
            }
            .navigationTitle("Family")
        }
    }
}
