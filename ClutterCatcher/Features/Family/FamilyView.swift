import SwiftUI

/// Placeholder until zone sharing lands (M3). M2 syncs the catalog to the
/// owner's own iCloud; inviting the household is the next milestone.
struct FamilyView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Family Sharing Is Coming", systemImage: "person.3")
            } description: {
                Text("Soon the whole household will share one catalog — everyone sees the same bins, and edits show up on everybody's phone. Until then, ClutterCatcher keeps your catalog in your own iCloud.")
            }
            .navigationTitle("Family")
        }
    }
}
