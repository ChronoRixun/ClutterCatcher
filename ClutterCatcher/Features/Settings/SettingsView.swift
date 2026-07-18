import SwiftUI

struct SettingsView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(SyncStatusModel.self) private var syncStatus

    @State private var stats = CatalogStats()
    @State private var isConfirmingReset = false

    private var repository: SettingsRepository { SettingsRepository(database: appDatabase) }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(short ?? "?") (\(build ?? "?"))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Catalog") {
                    LabeledContent("Rooms", value: "\(stats.roomCount)")
                    LabeledContent("Containers", value: "\(stats.containerCount)")
                    LabeledContent("Items", value: "\(stats.itemCount)")
                    LabeledContent("Categories", value: "\(stats.categoryCount)")
                }

                Section {
                    if let seededAt = stats.seedAppliedAt {
                        LabeledContent("Starter catalog") {
                            Text(seededAt, style: .date)
                        }
                    } else {
                        LabeledContent("Starter catalog", value: "Not applied")
                    }
                } footer: {
                    Text("The starter rooms and categories are applied once, on first launch.")
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Sync", value: syncStatus.label)
                }

                Section {
                    Button("Reset Catalog…", role: .destructive) {
                        isConfirmingReset = true
                    }
                } footer: {
                    Text("Deletes every room, container, item, and category — from iCloud too, once sync is on — then re-applies the starter catalog. Printed labels stop resolving.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Erase the whole catalog on this device?",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("Erase and Re-seed", role: .destructive) {
                    Task {
                        do {
                            try await repository.resetCatalogAndReseed()
                        } catch {
                            Log.data.error("Catalog reset failed: \(String(describing: error))")
                        }
                    }
                }
            } message: {
                Text("This cannot be undone.")
            }
            .task {
                do {
                    for try await value in repository.observeStats() {
                        stats = value
                    }
                } catch {
                    Log.data.error("Stats observation failed: \(String(describing: error))")
                }
            }
        }
    }
}
