import GRDB
import SwiftUI

/// The in-app view of `sync_events` — conflict outcomes and anything sync
/// had to drop or rebuild, without needing Console.app and a Mac. One list,
/// newest first; the full sync status surface is M6.
struct SyncActivityView: View {
    @Environment(\.appDatabase) private var appDatabase

    @State private var events: [SyncEvent] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView {
                    Label("No Sync Events", systemImage: "checkmark.icloud")
                } description: {
                    Text("Conflicts and anything sync had to drop or rebuild will show up here. Quiet is good.")
                }
                .opacity(isLoading ? 0 : 1)
            } else {
                List(events) { event in
                    SyncEventRow(event: event)
                        .themedRow()
                }
            }
        }
        .navigationTitle("Sync Activity")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") {
                    clearEvents()
                }
                .disabled(events.isEmpty)
            }
        }
        .task {
            do {
                let observation = appDatabase.observe { db in
                    try SyncEvent.order(Column("id").desc).fetchAll(db)
                }
                for try await value in observation {
                    events = value
                    isLoading = false
                }
            } catch {
                Log.sync.error("Sync activity observation failed: \(String(describing: error))")
                isLoading = false
            }
        }
    }

    private func clearEvents() {
        let database = appDatabase
        Task {
            do {
                _ = try await database.writer.write { db in
                    try SyncEvent.deleteAll(db)
                }
            } catch {
                Log.sync.error("Clearing sync activity failed: \(String(describing: error))")
            }
        }
    }
}

private struct SyncEventRow: View {
    let event: SyncEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .foregroundStyle(symbolTint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.summary)
                    .font(.subheadline)
                Text(event.occurredAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbolName: String {
        switch event.kind {
        case .localEditOverwritten: "arrow.triangle.2.circlepath"
        case .localEditWon: "checkmark.circle"
        case .localEditDroppedByDelete: "trash"
        case .serverRecordDropped: "exclamationmark.triangle"
        case .zoneRecovered: "icloud.and.arrow.up"
        case .syncIdentityReset: "person.crop.circle.badge.exclamationmark"
        case .joinedHousehold: "person.3"
        case .householdDisconnected: "icloud.slash"
        }
    }

    private var symbolTint: Color {
        switch event.kind {
        case .localEditOverwritten: .orange
        case .localEditWon: .green
        case .localEditDroppedByDelete: .red
        case .serverRecordDropped: .yellow
        case .zoneRecovered: .blue
        case .syncIdentityReset: .blue
        case .joinedHousehold: .green
        case .householdDisconnected: .red
        }
    }
}
