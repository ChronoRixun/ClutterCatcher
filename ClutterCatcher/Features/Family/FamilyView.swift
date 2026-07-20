import CloudKit
import GRDB
import SwiftUI

/// The household screen (M3-D/E). Owner: create the zone-wide share, invite,
/// manage participants, stop sharing. Participant: see the household, leave
/// it — or, after losing access, the way back in.
struct FamilyView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.syncCoordinator) private var syncCoordinator
    @Environment(AppModel.self) private var appModel
    @Environment(SyncStatusModel.self) private var syncStatus

    @State private var roster: [Participant] = []
    @State private var ownUserRecordName: String?
    @State private var share: CKShare?
    @State private var isWorking = false
    @State private var isPresentingShareSheet = false
    @State private var isConfirmingLeave = false
    @State private var errorMessage: String?

    private static let containerID = "iCloud.com.rixun.cluttercatcher"

    private var role: SyncRole? {
        if case .ready(let role) = appModel.bootstrapState { return role }
        return nil
    }

    var body: some View {
        NavigationStack {
            Group {
                switch role {
                case .owner:
                    ownerContent
                case .participant:
                    participantContent
                case nil:
                    ProgressView()
                }
            }
            .navigationTitle("Family")
            .themedScreen()
        }
        .alert(
            "Sharing Problem",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $isPresentingShareSheet) {
            if let share {
                CloudSharingView(
                    share: share,
                    container: CKContainer(identifier: Self.containerID),
                    onShareSaved: { Task { await refreshShareFromServer() } },
                    onStopSharing: { Task { await clearShareLocally() } },
                    onError: { error in errorMessage = error.localizedDescription })
            }
        }
        .task {
            await loadOwnIdentity()
            await loadArchivedShare()
            await refreshShareFromServer()
            await observeRoster()
        }
    }

    // MARK: Owner

    private var ownerContent: some View {
        Form {
            Section {
                if roster.isEmpty {
                    Text("No one else is in the household yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(roster, id: \.userRecordName) { participant in
                        ParticipantRow(
                            participant: participant,
                            isYou: participant.userRecordName == ownUserRecordName)
                    }
                }
            } header: {
                Text("Household")
            } footer: {
                Text("Everyone you invite can see and edit the whole catalog.")
            }
            .themedRow()

            Section {
                Button {
                    inviteTapped()
                } label: {
                    Label(
                        share == nil ? "Invite Your Family…" : "Manage Sharing…",
                        systemImage: "person.badge.plus")
                }
                .disabled(isWorking)
            } footer: {
                if share == nil {
                    Text("Sends an invite link through Messages or Mail. You stay the owner of the catalog.")
                }
            }
            .themedRow()
        }
        .overlay {
            if isWorking {
                ProgressView()
            }
        }
    }

    // MARK: Participant

    @ViewBuilder private var participantContent: some View {
        if syncStatus.phase == .disconnected {
            disconnectedContent
        } else {
            Form {
                Section {
                    if roster.isEmpty {
                        Text("Household members appear here once sync catches up.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(roster, id: \.userRecordName) { participant in
                            ParticipantRow(
                                participant: participant,
                                isYou: participant.userRecordName == ownUserRecordName)
                        }
                    }
                } header: {
                    Text("Household")
                } footer: {
                    Text("You're a member of this household — everyone shares one catalog.")
                }
                .themedRow()

                Section {
                    Button("Leave Household…", role: .destructive) {
                        isConfirmingLeave = true
                    }
                    .disabled(isWorking)
                } footer: {
                    Text("Your device keeps a copy of the catalog, but it stops syncing and your edits stay local.")
                }
                .themedRow()
            }
            .confirmationDialog(
                "Leave this household?",
                isPresented: $isConfirmingLeave,
                titleVisibility: .visible
            ) {
                Button("Leave Household", role: .destructive) {
                    leaveHousehold()
                }
            } message: {
                Text("This device keeps its current copy of the catalog but stops syncing.")
            }
        }
    }

    private var disconnectedContent: some View {
        ContentUnavailableView {
            Label("Not Connected", systemImage: "icloud.slash")
        } description: {
            Text("This device is no longer part of the household — the catalog you see is a local copy and no longer syncs.\n\nTo rejoin, ask the owner to send a fresh invite from their Family tab, then open the link on this device.")
        }
    }

    // MARK: Actions

    /// First use creates the zone-wide share (M3-D); after that the same
    /// button opens participant management on the existing share.
    private func inviteTapped() {
        Task {
            isWorking = true
            defer { isWorking = false }
            if share == nil {
                await refreshShareFromServer()
            }
            if share == nil {
                await createShare()
            }
            if share != nil {
                isPresentingShareSheet = true
            }
        }
    }

    private func createShare() async {
        let container = CKContainer(identifier: Self.containerID)
        let zoneID = SyncRole.owner.zoneID
        do {
            // The zone almost certainly exists (the engine saves it at first
            // start), but saving it again is harmless and removes the
            // zoneNotFound failure mode on a fresh Production container.
            _ = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            let newShare = HouseholdShare.makeShare(zoneID: zoneID)
            let result = try await container.privateCloudDatabase.modifyRecords(
                saving: [newShare], deleting: [])
            let saved = try result.saveResults[newShare.recordID]?.get()
            guard let savedShare = saved as? CKShare else {
                throw CKError(.internalError)
            }
            share = savedShare
            await persistShareLocally(savedShare)
        } catch {
            Log.sync.error("Share creation failed: \(String(describing: error))")
            // Name a permanent cause when we can (DL37/DL38 — "try again"
            // must never be the advice for a dead end like missing schema).
            let permanent = (error as? CKError)
                .flatMap { SyncCoordinator.permanentFailureMessage(for: $0.code) }
            errorMessage = permanent.map { "Couldn't set up sharing — \($0)." }
                ?? "Couldn't set up sharing — check that iCloud is reachable and try again."
        }
    }

    // MARK: Share persistence (M3-D: Family reflects reality after relaunch)

    private func loadArchivedShare() async {
        guard role?.isOwner == true, share == nil else { return }
        let data = try? await appDatabase.writer.read { db in
            try SyncState.fetchOne(db, key: SyncState.archivedShareKey)?.data
        }
        if let data, let archived = HouseholdShare.unarchive(data) {
            share = archived
        }
    }

    private func refreshShareFromServer() async {
        guard role?.isOwner == true else { return }
        let container = CKContainer(identifier: Self.containerID)
        let shareID = HouseholdShare.shareRecordID(in: SyncRole.owner.zoneID)
        do {
            let record = try await container.privateCloudDatabase.record(for: shareID)
            if let fetched = record as? CKShare {
                share = fetched
                await persistShareLocally(fetched)
            }
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            // No share (never created, or sharing stopped elsewhere).
            await clearShareLocally()
        } catch {
            // Offline etc. — keep the archived copy; the screen still works.
            Log.sync.info("Share refresh skipped: \(String(describing: error))")
        }
    }

    private func persistShareLocally(_ share: CKShare) async {
        let rosterEntries = HouseholdShare.roster(from: share)
        let archived = HouseholdShare.archive(share)
        do {
            try await appDatabase.writer.write { db in
                try Participant.replaceAll(db, with: rosterEntries)
                if let archived {
                    try SyncState(key: SyncState.archivedShareKey, data: archived)
                        .insert(db, onConflict: .replace)
                }
            }
        } catch {
            Log.sync.error("Persisting share failed: \(String(describing: error))")
        }
    }

    private func clearShareLocally() async {
        share = nil
        do {
            try await appDatabase.writer.write { db in
                try Participant.replaceAll(db, with: [])
                _ = try SyncState.deleteOne(db, key: SyncState.archivedShareKey)
            }
        } catch {
            Log.sync.error("Clearing share bookkeeping failed: \(String(describing: error))")
        }
    }

    private func leaveHousehold() {
        guard let syncCoordinator else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await syncCoordinator.leaveHousehold()
            } catch {
                Log.sync.error("Leave household failed: \(String(describing: error))")
                errorMessage = "Leaving didn't go through — check that iCloud is reachable and try again."
            }
        }
    }

    // MARK: Data

    private func loadOwnIdentity() async {
        ownUserRecordName = try? await appDatabase.writer.read { db in
            try SyncIdentityBookkeeping.storedUserRecordName(db)
        }
    }

    private func observeRoster() async {
        do {
            let observation = appDatabase.observe { db in
                try Participant
                    .order(Column("display_name").collating(.localizedCaseInsensitiveCompare))
                    .fetchAll(db)
            }
            for try await value in observation {
                roster = value
            }
        } catch {
            Log.data.error("Roster observation failed: \(String(describing: error))")
        }
    }
}

private struct ParticipantRow: View {
    let participant: Participant
    let isYou: Bool

    var body: some View {
        HStack {
            Image(systemName: "person.circle")
                .foregroundStyle(Color.accentColor)
            Text(participant.displayName)
            if isYou {
                Text("You")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}
