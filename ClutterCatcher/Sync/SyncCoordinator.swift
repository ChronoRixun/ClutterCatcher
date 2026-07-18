import CloudKit
import Foundation
import GRDB

/// Owns this device's CKSyncEngine (plan §3.2, M3 role-aware): the owner
/// runs a private-database engine against a zone it owns; a participant runs
/// a shared-database engine against the owner's zone. One engine per device,
/// never both — the delegate logic (mapping, LWW, receipts, orphans) is
/// shared; only the database and zone differ.
///
/// Responsibilities:
/// - engine lifecycle: role resolution, state serialization round-trip
///   through `sync_state`, `Household` zone creation (owner only), account
///   monitoring, sync-identity fingerprint enforcement;
/// - outbound: drains `pending_changes` in `nextRecordZoneChangeBatch`,
///   persists returned system fields and clears queue rows on ack, routes
///   `serverRecordChanged` through the LWW merge;
/// - inbound: applies fetched changes through `applyServerChanges` (never
///   the local-mutation path), persisting FK orphans until their parents
///   land; CKShare records refresh the participant roster instead;
/// - recovery: owner → zone recreate + re-upload; participant → degradation
///   (sync off, catalog kept, banner) — never zone recovery.
///
/// The app must stay fully functional with sync off: nothing here blocks the
/// UI, and every failure degrades to "changes stay queued locally".
actor SyncCoordinator {
    private let database: AppDatabase
    private let status: SyncStatusModel
    private let container: CKContainer

    private var engine: CKSyncEngine?
    private var started = false
    private var isRecoveringZone = false
    /// Set when the last send hit failures the engine won't retry and the
    /// app can't fix locally (e.g. schema not deployed). Kept so the status
    /// surface shows an honest error instead of an eternal "syncing…" while
    /// rows wait in the queue; cleared on the next send attempt (DL37).
    private var permanentSendFailure: String?
    /// The role the running engine was configured for, resolved at engine
    /// start. All zone identity flows from `role.zoneID` (M3-C).
    private var role: SyncRole?
    private var pendingObservationTask: Task<Void, Never>?
    private var accountMonitorTask: Task<Void, Never>?

    init(database: AppDatabase, status: SyncStatusModel) {
        self.database = database
        self.status = status
        self.container = CKContainer(identifier: "iCloud.com.rixun.cluttercatcher")
    }

    deinit {
        pendingObservationTask?.cancel()
        accountMonitorTask?.cancel()
    }

    // MARK: Lifecycle

    /// Called once from app bootstrap. Safe with no iCloud account or no
    /// role yet: sync stays off and the app runs local-only.
    func start() async {
        guard !started else { return }
        started = true
        accountMonitorTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                await self?.accountStatusChanged()
            }
        }
        await accountStatusChanged()
    }

    /// Re-resolves the role and restarts the engine accordingly. Called after
    /// onboarding picks "Set up this home" and after a share acceptance
    /// adopts the participant role.
    func roleDidChange() async {
        engine = nil
        pendingObservationTask?.cancel()
        pendingObservationTask = nil
        await accountStatusChanged()
    }

    /// Foreground hook: CloudKit pushes don't reliably reach simulators, and
    /// a fetch on activation keeps two-device gates observable (DL26). Also
    /// re-adds the durable queue to the engine's in-memory plan: after a
    /// permanent save failure the engine forgets those sends, and
    /// foregrounding — not a force-quit — should be enough to retry once
    /// the server-side problem is fixed (DL37).
    func applicationDidBecomeActive() async {
        if let engine, let zoneID = role?.zoneID {
            let pending = (try? await database.writer.read { db in
                try PendingChange.fetchAll(db)
            }) ?? []
            if !pending.isEmpty {
                engine.state.add(
                    pendingRecordZoneChanges: pending.map { $0.enginePendingChange(in: zoneID) })
            }
        }
        fetchSoon()
    }

    private func accountStatusChanged() async {
        // The persisted role is UI-relevant even when sync can't run (no
        // account, restricted) — publish it before any engine decision.
        if let persisted = try? await database.writer.read({ db in try SyncRole.load(db) }) {
            setRoleOnStatus(persisted)
        }
        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                await verifySyncIdentity()
                await startEngineIfNeeded()
            case .noAccount:
                stopEngine(reason: "no iCloud account")
            case .restricted:
                stopEngine(reason: "iCloud restricted")
            case .temporarilyUnavailable:
                stopEngine(reason: "iCloud temporarily unavailable")
            case .couldNotDetermine:
                stopEngine(reason: "iCloud unavailable")
            @unknown default:
                stopEngine(reason: "iCloud unavailable")
            }
        } catch {
            Log.sync.error("Account status check failed: \(String(describing: error))")
            stopEngine(reason: "iCloud unavailable")
        }
    }

    /// Sync bookkeeping is only valid for one (Apple ID, container
    /// environment) pair (M3-A, generalizing DL25). A mismatch of either
    /// resets it — the catalog stays, and backfill re-queues everything.
    private func verifySyncIdentity() async {
        guard let userRecordID = try? await container.userRecordID() else {
            Log.sync.info("userRecordID unavailable; skipping sync-identity check")
            return
        }
        let current = SyncIdentityFingerprint(
            userRecordName: userRecordID.recordName,
            environment: CloudKitEnvironment.current)
        do {
            let didReset = try await database.writer.write { db in
                try SyncIdentityBookkeeping.reconcile(db, current: current)
            }
            if didReset {
                Log.sync.warning("Sync identity changed; bookkeeping was reset")
                engine = nil
            }
        } catch {
            Log.sync.error("Sync-identity bookkeeping failed: \(String(describing: error))")
        }
    }

    private func startEngineIfNeeded() async {
        let resolved: (role: SyncRole?, joinPending: Bool, disconnected: Bool)
        do {
            resolved = try await database.writer.read { db in
                (try SyncRole.load(db),
                 try Setting.fetchOne(db, key: Setting.joinPendingKey) != nil,
                 try SyncState.fetchOne(db, key: SyncState.participantDisconnectedKey) != nil)
            }
        } catch {
            Log.sync.error("Role resolution failed: \(String(describing: error))")
            setStatus(.off(reason: "sync state unreadable"))
            return
        }
        guard let role = resolved.role else {
            self.role = nil
            setRoleOnStatus(nil)
            setStatus(.off(reason: resolved.joinPending
                ? "waiting for a household invite" : "not set up yet"))
            return
        }
        self.role = role
        setRoleOnStatus(role)
        if case .participant = role, resolved.disconnected {
            engine = nil
            setStatus(.disconnected)
            return
        }
        guard engine == nil else {
            await settleStatus()
            return
        }

        let serialization = await loadEngineState(key: Self.engineStateKey(for: role))
        let configuration = CKSyncEngine.Configuration(
            database: role.isOwner
                ? container.privateCloudDatabase
                : container.sharedCloudDatabase,
            stateSerialization: serialization,
            delegate: self)
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        Log.sync.info("\(role.isOwner ? "Private" : "Shared")-DB sync engine started (\(serialization == nil ? "fresh state" : "resumed state"))")

        if role.isOwner, serialization == nil {
            // First run for this identity: make sure the zone exists. Saving
            // an existing zone is harmless. Participants never create the
            // zone — it belongs to the owner.
            engine.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: role.zoneID)),
            ])
        }
        do {
            let backfilled = try await database.writer.write { db in
                try SyncBackfill.enqueueUnsyncedRows(db)
            }
            if backfilled > 0 {
                Log.sync.info("Backfill queued \(backfilled) unsynced row(s)")
            }
        } catch {
            Log.sync.error("Backfill failed: \(String(describing: error))")
        }
        await drainOrphans(fetchComplete: false)
        startPendingObservation()
        await settleStatus()
        fetchSoon()
    }

    private static func engineStateKey(for role: SyncRole) -> String {
        role.isOwner ? SyncState.privateEngineKey : SyncState.sharedEngineKey
    }

    private func stopEngine(reason: String) {
        if engine != nil {
            Log.sync.info("Sync engine stopped: \(reason)")
        }
        engine = nil
        pendingObservationTask?.cancel()
        pendingObservationTask = nil
        setStatus(.off(reason: reason))
    }

    private func fetchSoon() {
        guard let engine else { return }
        Task {
            do {
                try await engine.fetchChanges()
            } catch {
                // Offline is normal here; the engine retries on its own.
                Log.sync.info("Fetch not completed: \(String(describing: error))")
            }
        }
    }

    // MARK: Participant degradation (M3-E)

    /// Share revoked / participant removed / zone gone: sync turns off, the
    /// catalog stays local, and the UI shows a persistent banner. Never zone
    /// recovery — rebuilding the household zone is the owner's business.
    private func enterDisconnectedState(context: String) async {
        guard let role, !role.isOwner else { return }
        guard engine != nil else { return }
        Log.sync.warning("Participant lost household access (\(context)); sync off, catalog kept")
        engine = nil
        pendingObservationTask?.cancel()
        pendingObservationTask = nil
        do {
            try await database.writer.write { db in
                try SyncState(key: SyncState.participantDisconnectedKey, data: Data([1]))
                    .insert(db, onConflict: .replace)
                try SyncEvent.append(
                    db, kind: .householdDisconnected, recordType: nil, recordId: nil,
                    summary: "This device is no longer connected to the household — your catalog is safe on this device, but changes no longer sync.")
            }
        } catch {
            Log.sync.error("Recording disconnection failed: \(String(describing: error))")
        }
        setStatus(.disconnected)
    }

    /// Participant-initiated exit: deleting the `Household` zone from the
    /// shared database is CloudKit's way for a participant to remove
    /// themselves from the share; then the same degradation state applies.
    func leaveHousehold() async throws {
        guard let role, case .participant = role else { return }
        _ = try await container.sharedCloudDatabase.modifyRecordZones(
            saving: [], deleting: [role.zoneID])
        await enterDisconnectedState(context: "left household")
    }

    // MARK: Engine state persistence

    private func loadEngineState(key: String) async -> CKSyncEngine.State.Serialization? {
        do {
            guard let stored = try await database.writer.read({ db in
                try SyncState.fetchOne(db, key: key)?.data
            }) else { return nil }
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: stored)
        } catch {
            Log.sync.error("Engine state unreadable, starting fresh: \(String(describing: error))")
            return nil
        }
    }

    private func persistEngineState(_ serialization: CKSyncEngine.State.Serialization) async {
        guard let role else { return }
        let key = Self.engineStateKey(for: role)
        do {
            let data = try JSONEncoder().encode(serialization)
            try await database.writer.write { db in
                try SyncState(key: key, data: data)
                    .insert(db, onConflict: .replace)
            }
        } catch {
            Log.sync.error("Persisting engine state failed: \(String(describing: error))")
        }
    }

    // MARK: Outbound queue → engine state

    /// `pending_changes` is the durable queue; the engine's in-memory state
    /// is rebuilt from it via this observation — every local mutation lands
    /// here without repositories knowing sync exists.
    private func startPendingObservation() {
        pendingObservationTask?.cancel()
        pendingObservationTask = Task { [weak self, database] in
            do {
                let observation = database.observe { db in
                    try PendingChange.fetchAll(db)
                }
                for try await pending in observation {
                    await self?.reconcileEnginePending(pending)
                }
            } catch {
                Log.sync.error("Pending-change observation ended: \(String(describing: error))")
            }
        }
    }

    private func reconcileEnginePending(_ pending: [PendingChange]) async {
        guard let engine, let zoneID = role?.zoneID, !pending.isEmpty else { return }
        engine.state.add(
            pendingRecordZoneChanges: pending.map { $0.enginePendingChange(in: zoneID) })
    }

    // MARK: Status

    private func setStatus(_ phase: SyncStatusModel.Phase) {
        let status = status
        Task { @MainActor in
            status.phase = phase
        }
    }

    private func setRoleOnStatus(_ role: SyncRole?) {
        let status = status
        Task { @MainActor in
            status.role = role
        }
    }

    private func settleStatus() async {
        guard engine != nil else { return }
        let pendingCount = (try? await database.writer.read { db in
            try PendingChange.fetchCount(db)
        }) ?? 0
        if pendingCount == 0 {
            permanentSendFailure = nil
            setStatus(.upToDate)
        } else if let permanentSendFailure {
            setStatus(.error(message: permanentSendFailure))
        } else {
            setStatus(.syncing)
        }
    }

    /// A user-visible explanation for save/delete failures the engine won't
    /// retry on its own and the app can't fix locally — nil for codes that
    /// are transient (the engine retries) or have dedicated handling. The
    /// queue row always survives either way; this only keeps the status
    /// surface honest (DL37: "syncing…" must never mask a dead end).
    static func permanentFailureMessage(for code: CKError.Code) -> String? {
        switch code {
        case .invalidArguments:
            // The classic (D15 Step 0): record types not deployed to this
            // environment. Nothing to do app-side until the Console deploy.
            return "iCloud can't accept changes yet — schema not deployed"
        case .permissionFailure:
            return "iCloud denied the change (no write permission)"
        case .quotaExceeded:
            return "iCloud storage is full"
        case .serverRecordChanged, .zoneNotFound, .unknownItem,
             .networkFailure, .networkUnavailable, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .notAuthenticated:
            return nil
        default:
            return "some changes can't reach iCloud right now"
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension SyncCoordinator: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            await persistEngineState(stateUpdate.stateSerialization)
        case .accountChange(let accountChange):
            await handleAccountChange(accountChange)
        case .fetchedDatabaseChanges(let changes):
            await handleFetchedDatabaseChanges(changes)
        case .fetchedRecordZoneChanges(let changes):
            await handleFetchedRecordZoneChanges(changes)
        case .sentRecordZoneChanges(let sent):
            await handleSentRecordZoneChanges(sent)
        case .sentDatabaseChanges(let sent):
            handleSentDatabaseChanges(sent)
        case .willFetchChanges:
            setStatus(.syncing)
        case .willSendChanges:
            // A fresh attempt: stale permanent-failure verdicts don't stick.
            permanentSendFailure = nil
            setStatus(.syncing)
        case .didFetchChanges:
            await drainOrphans(fetchComplete: true)
            await settleStatus()
        case .didSendChanges:
            await settleStatus()
        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break
        @unknown default:
            Log.sync.info("Unhandled sync engine event: \(String(describing: event))")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let zoneID = role?.zoneID else { return nil }
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        let database = database
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            let id = recordID.recordName
            let snapshot: (row: SyncedRow, systemFields: Data?)?
            do {
                snapshot = try await database.writer.read { db in
                    guard let row = try SyncedRow.fetch(db, id: id) else { return nil }
                    let metadata = try RecordMetadata.fetchOne(db, key: id)
                    return (row, metadata?.systemFields)
                }
            } catch {
                Log.sync.error("Loading \(id) for send failed: \(String(describing: error))")
                return nil // stays pending; retried on the next send
            }
            guard let snapshot else {
                // Row vanished after being queued (e.g. swept by an inbound
                // cascade) — drop the stale save.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                try? await database.writer.write { db in
                    try db.execute(
                        sql: "DELETE FROM pending_changes WHERE record_id = ? AND change_kind = 'save'",
                        arguments: [id])
                }
                return nil
            }
            return RecordMapper.record(
                for: snapshot.row, systemFields: snapshot.systemFields, zoneID: zoneID)
        }
    }
}

// MARK: - Event handling
// Internal (not private) so the test suite can drive the inbound paths —
// notably the persistent orphan drain — without a live engine.

extension SyncCoordinator {
    func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) async {
        switch event.changeType {
        case .signIn:
            Log.sync.info("iCloud account signed in")
            await accountStatusChanged()
        case .signOut:
            Log.sync.info("iCloud account signed out; data stays local")
            stopEngine(reason: "no iCloud account")
        case .switchAccounts:
            Log.sync.warning("iCloud account switched; re-verifying sync identity")
            engine = nil
            pendingObservationTask?.cancel()
            pendingObservationTask = nil
            // The fingerprint check inside accountStatusChanged does the
            // bookkeeping reset with the new account's userRecordID.
            await accountStatusChanged()
        @unknown default:
            Log.sync.info("Unhandled account change")
        }
    }

    func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) async {
        guard let role else { return }
        for deletion in event.deletions where deletion.zoneID == role.zoneID {
            if role.isOwner {
                Log.sync.warning(
                    "Household zone deleted on server (\(String(describing: deletion.reason)))")
                await recoverFromMissingZone(context: "database change")
            } else {
                await enterDisconnectedState(context: "zone removed from shared database")
            }
        }
    }

    func handleFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        var parsed: [ParsedServerRecord] = []
        var unparseable: [(type: String, id: String)] = []
        for modification in event.modifications {
            let record = modification.record
            if let share = record as? CKShare {
                await handleFetchedShare(share)
                continue
            }
            do {
                parsed.append(try RecordMapper.parse(record))
            } catch {
                Log.sync.error("Dropping unparseable server record \(record.recordID.recordName): \(String(describing: error))")
                unparseable.append((record.recordType, record.recordID.recordName))
            }
        }
        if !unparseable.isEmpty {
            let receipts = unparseable
            try? await database.writer.write { db in
                for entry in receipts {
                    try SyncEvent.append(
                        db, kind: .serverRecordDropped,
                        recordType: SyncRecordType(rawValue: entry.type), recordId: entry.id,
                        summary: "A record from iCloud (\(entry.type)) couldn't be read and was skipped.")
                }
            }
        }
        var deletions: [(type: SyncRecordType, id: String)] = []
        var shareDeleted = false
        for deletion in event.deletions {
            if deletion.recordID.recordName == CKRecordNameZoneWideShare
                || deletion.recordType == CKRecord.SystemType.share {
                shareDeleted = true
                continue
            }
            guard let type = SyncRecordType(rawValue: deletion.recordType) else {
                Log.sync.info("Ignoring deletion of unknown record type \(deletion.recordType)")
                continue
            }
            deletions.append((type, deletion.recordID.recordName))
        }
        await applyServerBatch(saves: parsed, deletions: deletions)
        if shareDeleted {
            await handleShareDeletion()
        }
    }

    /// The zone-wide CKShare arrives through the same fetch pipeline as our
    /// records; it never touches the catalog — it refreshes the participant
    /// roster (D11) and, for the owner, the archived copy the Family screen
    /// shows before its live refetch lands.
    func handleFetchedShare(_ share: CKShare) async {
        let roster = HouseholdShare.roster(from: share)
        let archived = (role?.isOwner == true) ? HouseholdShare.archive(share) : nil
        do {
            try await database.writer.write { db in
                try Participant.replaceAll(db, with: roster)
                if let archived {
                    try SyncState(key: SyncState.archivedShareKey, data: archived)
                        .insert(db, onConflict: .replace)
                }
            }
        } catch {
            Log.sync.error("Roster refresh failed: \(String(describing: error))")
        }
    }

    /// The share record was deleted: for the owner that means sharing was
    /// stopped (possibly from another device or the Console) — the private
    /// zone and catalog are untouched. For a participant it means access is
    /// gone (the zone deletion usually arrives too; either signal degrades).
    func handleShareDeletion() async {
        guard let role else { return }
        if role.isOwner {
            Log.sync.info("Household share deleted; sharing is off, catalog unaffected")
            try? await database.writer.write { db in
                try Participant.replaceAll(db, with: [])
                _ = try SyncState.deleteOne(db, key: SyncState.archivedShareKey)
            }
        } else {
            await enterDisconnectedState(context: "share revoked")
        }
    }

    func applyServerBatch(
        saves: [ParsedServerRecord],
        deletions: [(type: SyncRecordType, id: String)]
    ) async {
        let sortedSaves = Self.sortedParentsFirst(saves)
        let sortedDeletions = deletions.sorted {
            Self.typeIndex($0.type) > Self.typeIndex($1.type) // children first
        }
        do {
            let outcome = try await database.applyServerChanges { apply in
                var dropped: [PendingChange] = []
                for record in sortedSaves {
                    let pendingBefore = try PendingChange.fetchOne(apply.db, key: record.row.id)
                    switch try apply.applyWithMerge(record) {
                    case .orphaned:
                        // Persisted, not buffered in memory: a crash between
                        // this batch and the drain must not lose it (M3-G).
                        try OrphanedRecord.buffer(apply.db, records: [record], at: Date())
                    case .applied:
                        _ = try OrphanedRecord.deleteOne(apply.db, key: record.row.id)
                        if let pendingBefore {
                            dropped.append(pendingBefore)
                        }
                    case .keptLocal:
                        _ = try OrphanedRecord.deleteOne(apply.db, key: record.row.id)
                    }
                }
                for deletion in sortedDeletions {
                    dropped += try apply.applyDeletion(type: deletion.type, id: deletion.id)
                    _ = try OrphanedRecord.deleteOne(apply.db, key: deletion.id)
                }
                return dropped
            }
            if let zoneID = role?.zoneID, !outcome.isEmpty {
                engine?.state.remove(
                    pendingRecordZoneChanges: outcome.map { $0.enginePendingChange(in: zoneID) })
            }
            if !outcome.filter({ $0.changeKind == .save }).isEmpty {
                Log.sync.info("Server changes superseded \(outcome.count) queued local change(s) (LWW)")
            }
            await drainOrphans(fetchComplete: false)
        } catch {
            Log.sync.error("Applying fetched changes failed: \(String(describing: error))")
            setStatus(.error(message: "couldn't apply changes from iCloud"))
        }
    }

    /// Retries persisted FK orphans. Mid-fetch, whatever still fails stays in
    /// the table; once the fetch is complete, an item missing only its
    /// category is salvaged without the reference, and anything else is
    /// dropped with a receipt (its parent is genuinely gone). Runs on
    /// coordinator start too — that's what makes the persistence matter.
    func drainOrphans(fetchComplete: Bool) async {
        do {
            try await database.applyServerChanges { apply in
                let buffered = Self.sortedParentsFirst(try OrphanedRecord.loadAll(apply.db))
                guard !buffered.isEmpty else { return }
                var still: [ParsedServerRecord] = []
                for record in buffered {
                    if try apply.applyWithMerge(record) == .orphaned {
                        still.append(record)
                    } else {
                        _ = try OrphanedRecord.deleteOne(apply.db, key: record.row.id)
                    }
                }
                guard fetchComplete else { return } // the rest keep waiting

                var droppedRecords: [ParsedServerRecord] = []
                for record in still {
                    if case .item(var item) = record.row, item.categoryId != nil {
                        item.categoryId = nil
                        let salvaged = ParsedServerRecord(
                            row: .item(item), systemFields: record.systemFields)
                        if try apply.applyWithMerge(salvaged) == .orphaned {
                            droppedRecords.append(record)
                        }
                    } else {
                        droppedRecords.append(record)
                    }
                    _ = try OrphanedRecord.deleteOne(apply.db, key: record.row.id)
                }
                for record in droppedRecords {
                    try SyncEvent.append(
                        apply.db, kind: .serverRecordDropped,
                        recordType: record.row.recordType, recordId: record.row.id,
                        summary: "\(record.row.displayName) — arrived from iCloud without a surviving parent and was not applied.")
                }
                if !droppedRecords.isEmpty {
                    Log.sync.warning("Dropped \(droppedRecords.count) fetched record(s) whose parent no longer exists")
                }
            }
        } catch {
            Log.sync.error("Orphan drain failed: \(String(describing: error))")
        }
    }

    func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) async {
        let saved = event.savedRecords.map { record in
            SavedSnapshot(
                id: record.recordID.recordName,
                type: SyncRecordType(rawValue: record.recordType),
                systemFields: record.encodedSystemFields(),
                sentUpdatedAt: record["updated_at"] as? Date)
        }
        let deletedIDs = event.deletedRecordIDs.map(\.recordName)
        do {
            try await database.writer.write { [saved, deletedIDs] db in
                for snapshot in saved {
                    guard let type = snapshot.type else { continue }
                    try RecordMetadata(
                        recordId: snapshot.id,
                        recordType: type,
                        systemFields: snapshot.systemFields
                    ).insert(db, onConflict: .replace)
                    guard let pending = try PendingChange.fetchOne(db, key: snapshot.id),
                          pending.changeKind == .save else { continue }
                    // If the row was edited again while this save was in
                    // flight, its stamp is newer than what we sent — keep it
                    // queued so the newer edit still uploads.
                    let row = try SyncedRow.fetch(db, type: type, id: snapshot.id)
                    if let rowUpdatedAt = row?.updatedAt,
                       let sent = snapshot.sentUpdatedAt,
                       rowUpdatedAt > sent.addingTimeInterval(0.0005) {
                        continue
                    }
                    try pending.delete(db)
                }
                for id in deletedIDs {
                    if let pending = try PendingChange.fetchOne(db, key: id),
                       pending.changeKind == .delete {
                        try pending.delete(db)
                    }
                    _ = try RecordMetadata.deleteOne(db, key: id)
                }
            }
        } catch {
            Log.sync.error("Recording sent changes failed: \(String(describing: error))")
        }

        for failure in event.failedRecordSaves {
            await handleFailedSave(failure)
        }
        for (recordID, error) in event.failedRecordDeletes {
            await handleFailedDelete(recordID, error)
        }
    }

    func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) async {
        let record = failure.record
        let error = failure.error
        let id = record.recordID.recordName
        switch error.code {
        case .serverRecordChanged:
            guard let serverRecord = error.serverRecord else {
                Log.sync.error("serverRecordChanged without a server record for \(id)")
                return
            }
            await resolveConflict(serverRecord: serverRecord)
        case .zoneNotFound:
            await handleMissingZone(context: "record save")
        case .unknownItem:
            // Deleted server-side while our edit was in flight. Deletion wins
            // (the same rule as inbound deletes); the fetch delivers the
            // deletion for the local row.
            Log.sync.warning("Dropping local save for \(id): record was deleted on the server")
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            let type = SyncRecordType(rawValue: record.recordType)
            try? await database.writer.write { db in
                _ = try PendingChange.deleteOne(db, key: id)
                _ = try RecordMetadata.deleteOne(db, key: id)
                if let type {
                    let name = try SyncedRow.fetch(db, type: type, id: id)?.displayName ?? id
                    try SyncEvent.append(
                        db, kind: .localEditDroppedByDelete, recordType: type, recordId: id,
                        summary: "\(name) — deleted on another device while you had unsent changes; your edit was discarded.")
                }
            }
        case .networkFailure, .networkUnavailable, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .notAuthenticated:
            // Transient — the engine retries on its own; the queue row stays.
            Log.sync.info("Transient save failure for \(id): \(error.code.rawValue)")
        default:
            // Permanent until something changes server-side. The queue row
            // stays (the edit is not lost); the status surface says so.
            Log.sync.error("Permanent save failure for \(id): \(String(describing: error))")
            if let message = Self.permanentFailureMessage(for: error.code) {
                permanentSendFailure = message
            }
        }
    }

    /// `serverRecordChanged`: another device won the race to this record.
    /// LWW decides (D10): if our row is newer we re-apply our values on top
    /// of the server's change tag and re-send; otherwise the server copy is
    /// applied locally and our stale save is dropped.
    func resolveConflict(serverRecord: CKRecord) async {
        let recordID = serverRecord.recordID
        let parsed: ParsedServerRecord
        do {
            parsed = try RecordMapper.parse(serverRecord)
        } catch {
            // The server copy is malformed (Console experiment?). Adopt its
            // change tag and re-send local truth over it.
            Log.sync.warning("Conflict with unparseable server record \(recordID.recordName); keeping local values")
            guard let type = SyncRecordType(rawValue: serverRecord.recordType) else { return }
            let systemFields = serverRecord.encodedSystemFields()
            try? await database.writer.write { db in
                try RecordMetadata(
                    recordId: recordID.recordName, recordType: type, systemFields: systemFields
                ).insert(db, onConflict: .replace)
            }
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return
        }
        do {
            let outcome = try await database.applyServerChanges { apply in
                let pendingBefore = try PendingChange.fetchOne(apply.db, key: parsed.row.id)
                let result = try apply.applyWithMerge(parsed)
                if result == .orphaned {
                    try OrphanedRecord.buffer(apply.db, records: [parsed], at: Date())
                }
                return ConflictOutcome(result: result, pendingBefore: pendingBefore)
            }
            switch outcome.result {
            case .keptLocal:
                Log.sync.info("Conflict on \(parsed.row.id): local edit is newer, re-sending")
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                // A send-conflict is a true two-device divergence (unlike
                // routine fetch echoes), so the winning side gets a receipt
                // too — that's what makes LWW verifiable from either phone.
                let row = parsed.row
                try? await database.writer.write { db in
                    let localName = try SyncedRow
                        .fetch(db, type: row.recordType, id: row.id)?.displayName
                    try SyncEvent.append(
                        db, kind: .localEditWon,
                        recordType: row.recordType, recordId: row.id,
                        summary: "\(localName ?? row.displayName) — edited on two devices; your more recent change won.")
                }
            case .applied:
                Log.sync.info("Conflict on \(parsed.row.id): server edit is newer, accepted")
                if let pending = outcome.pendingBefore, let zoneID = role?.zoneID {
                    engine?.state.remove(
                        pendingRecordZoneChanges: [pending.enginePendingChange(in: zoneID)])
                }
            case .orphaned:
                // Parent hasn't reached us yet — persisted above; pull.
                fetchSoon()
            }
        } catch {
            Log.sync.error("Conflict resolution for \(parsed.row.id) failed: \(String(describing: error))")
        }
    }

    func handleFailedDelete(_ recordID: CKRecord.ID, _ error: CKError) async {
        let id = recordID.recordName
        switch error.code {
        case .unknownItem:
            // Already gone server-side — as good as done.
            engine?.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            try? await database.writer.write { db in
                if let pending = try PendingChange.fetchOne(db, key: id),
                   pending.changeKind == .delete {
                    try pending.delete(db)
                }
                _ = try RecordMetadata.deleteOne(db, key: id)
            }
        case .zoneNotFound:
            await handleMissingZone(context: "record delete")
        case .networkFailure, .networkUnavailable, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .notAuthenticated:
            Log.sync.info("Transient delete failure for \(id): \(error.code.rawValue)")
        default:
            Log.sync.error("Permanent delete failure for \(id): \(String(describing: error))")
            if let message = Self.permanentFailureMessage(for: error.code) {
                permanentSendFailure = message
            }
        }
    }

    func handleSentDatabaseChanges(_ event: CKSyncEngine.Event.SentDatabaseChanges) {
        for zone in event.savedZones where zone.zoneID.zoneName == RecordMapper.zoneName {
            Log.sync.info("Household zone saved")
        }
        for failure in event.failedZoneSaves {
            Log.sync.error("Zone save failed: \(String(describing: failure.error))")
        }
    }

    /// The zone is gone. Who fixes it depends on the role: the owner recreates
    /// and re-uploads; a participant degrades — the household zone is not
    /// theirs to rebuild.
    func handleMissingZone(context: String) async {
        guard let role else { return }
        if role.isOwner {
            await recoverFromMissingZone(context: context)
        } else {
            await enterDisconnectedState(context: context)
        }
    }

    /// Owner only. Zone deleted / data purged / zoneNotFound: the server no
    /// longer has our records, so every archived change tag is void. Recreate
    /// the zone and re-queue the whole catalog. Guarded so a burst of
    /// per-record zoneNotFound failures runs one recovery, not a loop — and
    /// the engine's own send scheduling paces any retry after a failed
    /// recovery.
    func recoverFromMissingZone(context: String) async {
        guard !isRecoveringZone else { return }
        isRecoveringZone = true
        defer { isRecoveringZone = false }
        Log.sync.warning("Household zone missing (\(context)); recreating and re-uploading")
        do {
            try await database.writer.write { db in
                try RecordMetadata.deleteAll(db)
                try OrphanedRecord.deleteAll(db)
                // Deletes aimed at records the vanished zone held are moot.
                try db.execute(sql: "DELETE FROM pending_changes WHERE change_kind = 'delete'")
                try SyncBackfill.enqueueUnsyncedRows(db)
                try SyncEvent.append(
                    db, kind: .zoneRecovered, recordType: nil, recordId: nil,
                    summary: "iCloud data for this app was missing or reset — rebuilding it from this device's catalog.")
            }
            if let engine, let role {
                let staleDeletes = engine.state.pendingRecordZoneChanges.filter {
                    if case .deleteRecord = $0 { return true }
                    return false
                }
                engine.state.remove(pendingRecordZoneChanges: staleDeletes)
                engine.state.add(pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: role.zoneID)),
                ])
            }
        } catch {
            Log.sync.error("Zone recovery failed: \(String(describing: error))")
        }
    }

    // MARK: Helpers

    static func sortedParentsFirst(_ records: [ParsedServerRecord]) -> [ParsedServerRecord] {
        records.sorted { typeIndex($0.row.recordType) < typeIndex($1.row.recordType) }
    }

    static func typeIndex(_ type: SyncRecordType) -> Int {
        SyncRecordType.parentsFirst.firstIndex(of: type) ?? SyncRecordType.parentsFirst.count
    }
}

// MARK: - Support types

private struct ConflictOutcome: Sendable {
    var result: ServerApply.ApplyOutcome
    var pendingBefore: PendingChange?
}

private struct SavedSnapshot: Sendable {
    var id: String
    var type: SyncRecordType?
    var systemFields: Data
    var sentUpdatedAt: Date?
}

extension PendingChange {
    func ckRecordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordId, zoneID: zoneID)
    }

    func enginePendingChange(in zoneID: CKRecordZone.ID) -> CKSyncEngine.PendingRecordZoneChange {
        switch changeKind {
        case .save: .saveRecord(ckRecordID(in: zoneID))
        case .delete: .deleteRecord(ckRecordID(in: zoneID))
        }
    }
}
