import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.syncCoordinator) private var coordinator
    @Environment(SyncStatusModel.self) private var syncStatus
    @Environment(AppModel.self) private var appModel
    @Environment(\.photoStore) private var photoStore
    @Environment(ThemeStore.self) private var themeStore

    @State private var stats = CatalogStats()
    @State private var isConfirmingReset = false
    @State private var isCleaningPhotos = false
    @State private var photoCleanupResult: String?
    /// The active alternate-icon name, re-read whenever this screen appears
    /// (the pickers may have changed it).
    @State private var currentIconName: String?

    private var repository: SettingsRepository { SettingsRepository(database: appDatabase) }

    /// Reset is owner-only (M3-D, Owen's ruling): in participant role the
    /// row is disabled with one line of explanation.
    private var isParticipant: Bool {
        if case .ready(.participant) = appModel.bootstrapState { return true }
        return false
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(short ?? "?") (\(build ?? "?"))"
    }

    /// Display name for the App Icon row: the matching entry's, or Classic's
    /// when no alternate is set.
    private var currentIconDisplayName: String {
        AppIcons.entry(forIconName: currentIconName)?.displayName ?? "Classic"
    }

    var body: some View {
        NavigationStack {
            Form {
                // M4 (§4): personalization on top — local, per-device state.
                Section {
                    NavigationLink {
                        ThemePickerView()
                    } label: {
                        LabeledContent("Theme", value: themeStore.theme.displayName)
                    }
                    NavigationLink {
                        AppIconPickerView()
                    } label: {
                        LabeledContent("App Icon", value: currentIconDisplayName)
                    }
                } header: {
                    Text("Make It Yours")
                } footer: {
                    Text("Theme and icon are yours alone — everyone in the family picks their own.")
                }
                .themedRow()

                Section("Catalog") {
                    LabeledContent("Rooms", value: "\(stats.roomCount)")
                    LabeledContent("Containers", value: "\(stats.containerCount)")
                    LabeledContent("Items", value: "\(stats.itemCount)")
                    LabeledContent("Categories", value: "\(stats.categoryCount)")
                }
                .themedRow()

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
                .themedRow()

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Sync", value: syncStatus.label)
                    NavigationLink("Sync Activity") {
                        SyncActivityView()
                    }
                }
                .themedRow()

                Section {
                    Button("Re-download Photos") {
                        Task { await coordinator?.requestPhotoRefetch() }
                    }
                    .disabled(coordinator == nil)
                } footer: {
                    Text("Fetches item photos that haven't reached this device yet — after a reinstall, or if a photo is showing a placeholder.")
                }
                .themedRow()

                Section {
                    Button("Clean Up Unused Photos") {
                        isCleaningPhotos = true
                        photoCleanupResult = nil
                        Task {
                            await runPhotoCleanup()
                            isCleaningPhotos = false
                        }
                    }
                    .disabled(isCleaningPhotos)
                } footer: {
                    if let photoCleanupResult {
                        Text(photoCleanupResult)
                    } else {
                        Text("Removes cached photo files that no item uses anymore. Photos still in use are never touched.")
                    }
                }
                .themedRow()

                Section {
                    Button("Reset Catalog…", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .disabled(isParticipant)
                    // Anchored to its row so iPad presents a sane popover
                    // (M6.2 popover audit).
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
                } footer: {
                    if isParticipant {
                        Text("Only the household owner can reset the shared catalog.")
                    } else {
                        Text("Deletes every room, container, item, and category — from iCloud too, once sync is on — then re-applies the starter catalog. Printed labels stop resolving.")
                    }
                }
                .themedRow()
            }
            // M6.2: readable width in regular width; no-op on compact.
            .readableContentWidth()
            .navigationTitle("Settings")
            .themedScreen()
            .onAppear {
                currentIconName = UIApplication.shared.alternateIconName
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

    /// P18/P19/P20: assemble the live ref set (items table ∪ orphan buffer),
    /// then sweep off the main actor. If the live set can't be read there is
    /// no safe sweep at all — never guess at what's referenced.
    private func runPhotoCleanup() async {
        do {
            let live = try await repository.livePhotoRefs()
            let store = photoStore
            let cutoff = Date.now.addingTimeInterval(-PhotoStore.sweepAgeGuard)
            let result = await Task.detached(priority: .utility) {
                store.sweepUnusedPhotos(keeping: live, olderThan: cutoff)
            }.value
            if result.filesRemoved == 0 {
                photoCleanupResult = "Nothing to clean up."
            } else {
                let files = result.filesRemoved == 1 ? "1 file" : "\(result.filesRemoved) files"
                let freed = result.bytesFreed.formatted(.byteCount(style: .file))
                photoCleanupResult = "Removed \(files), freed \(freed)."
            }
        } catch {
            Log.data.error("Photo cleanup failed reading the live set: \(String(describing: error))")
            photoCleanupResult = "Couldn't clean up right now."
        }
    }
}
