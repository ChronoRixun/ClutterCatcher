# OPEN_ITEMS — decision log & open questions

Convention per D17: decisions made during implementation get logged here with
rationale; product questions the plan doesn't answer go under **Questions for
Owen** with the chosen (most reversible) interim answer marked.

## Decision log

### 2026-07-18 — Run 1 (M0 + M1)

- **DL1 — Model ids are `String`, not `UUID`.** GRDB stores Swift `UUID`
  values as 16-byte BLOBs by default; D9 wants TEXT primary keys that double
  as CKRecord recordNames. Models therefore carry uppercase UUID strings
  (`AppDatabase.newID()`), and QR/deep-link parsing normalizes through
  `UUID` → `uuidString`, so lowercase scans match the stored keys.
- **DL2 — Record structs exist only for tables M1 touches.** `sync_state`,
  `record_metadata`, and `pending_changes` are created by migration `v1` (per
  plan §3.1) but get their Swift record types in M2 with their first consumer
  — no dead code now.
- **DL3 — No `eraseDatabaseOnSchemaChange`.** Even in DEBUG. Dev-signed
  direct installs (D14) mean family devices may run debug-ish builds against
  real data; schema changes always go through numbered migrations.
- **DL4 — GRDB pinned `from: 7.0.0`** (Swift 6 strict-concurrency-ready line).
- **DL5 — Deep links/scans replace the catalog navigation stack** rather than
  pushing onto it: scanning a bin answers "what's in this?" immediately, with
  no stale stack behind it. Unknown UUIDs still navigate; the detail screen
  owns the friendly "Not in Your Catalog" state (so the same path covers a
  label whose container was deleted).
- **DL6 — Scanner fallback.** `DataScannerViewController` is unsupported in
  the simulator, so ScanView falls back to a manual code-entry field there
  (also covers devices that deny camera access). Camera scanning itself is a
  device-only verification step.
- **DL7 — Label slots are a global monotonic sequence** assigned at first
  print (`MAX(label_slot) + 1`), permanent per container; sheets render the
  selected containers in slot order, filling cells sequentially. Simple, and
  the "pull before allocating" hook for D10 lives in one place
  (`ContainerRepository.assignLabelSlots`).
- **DL8 — Generated files stay generated.** `Info.plist` and the
  `.entitlements` are defined as properties in `project.yml` and emitted by
  `xcodegen generate`; the `.xcodeproj` and both files are gitignored.
- **DL9 — Seed flag value is the ISO-8601 apply date**, not a bare "true" —
  Settings shows when the starter catalog landed (written with
  `.formatted(.iso8601)`, parsed with the matching `.iso8601` strategy).
- **DL10 — Room deletion asks first.** Deleting a room cascades to all its
  containers and items (and in M2+ mirrors as CK deletes for the household),
  so the swipe/Edit delete is gated behind a confirmation dialog. Container
  deletion keeps its existing confirmation; item deletes stay swipe-only.
- **DL11 — Camera permission is requested explicitly.** The Scan tab gates on
  `DataScannerViewController.isSupported` only; `AVCaptureDevice
  .requestAccess` runs on first visit (`isAvailable` is false before the
  prompt, so gating on it would make scanning unreachable). Denied access
  falls back to manual entry with Settings guidance. The scanner also stops
  whenever another tab is selected — a successful scan switches tabs, and the
  capture session must not stay live behind it.
- **DL12 — Post-review hardening (same run).** An 8-angle self-review pass
  (no compiler available here) led to: `String(describing:)` in all Logger
  interpolations (`os.Logger` can't interpolate a bare `any Error`); GRDB
  added as an explicit test-target dependency; batch delete repository
  methods (one transaction per gesture); label text clamped + clipped to its
  cell so long names can't print across sticker boundaries; PDF rendering
  moved off the main actor; renderer pagination now uses the same
  `position(forLabelIndex:)` the layout tests exercise; deep links dismiss
  any open sheets on the Rooms tab; editors surface save failures in an
  alert instead of only logging; search observation debounced 250 ms;
  loading states guard empty-state flashes; name trimming centralized in
  repositories (`String.normalizedName` / `Optional<String>.normalizedNotes`).

### 2026-07-17 — Run 1.1 (first-build gate + Owen's answers)

- **DL13 — First-build fixups (the suite's first compile).** Swift Testing's
  `#expect` can't wrap throwing expressions inside GRDB's `read` closures
  ("errors thrown from here are not handled"); throwing calls are hoisted to
  `let` bindings before the `#expect` (MigrationTests, SeedTests). The
  `nonisolated(unsafe)` on `QRCodeGenerator.context` is unnecessary in the
  shipped SDK (CIContext is Sendable there) and got removed. The
  `Task.detached` PDF render passed strict concurrency untouched.
- **DL14 — Scripts pin the simulator runtime.** A bare `name=` destination
  resolves OS to *latest* (27.0 on this Mac), where no "iPhone 17" sim
  exists; scripts now pass `OS=${SIM_OS:-26.5}` — matching the iOS 26
  deployment target — and an iPhone 17 (iOS 26.5) simulator was created.
- **DL15 — Seed rooms are Owen's 12** (Q1 resolved): renamed rooms keep
  their original UUIDs (nothing shipped, so recordName continuity is free),
  four new rooms get fresh fixed UUIDs; sort_order = list order.
- **DL16 — Label sheets can start at any cell** (Q5 resolved): spec and
  renderer take a start offset (`position(forLabelIndex:startingAt:)`,
  `pageCount(forLabelCount:startingAt:)`), the sheet UI adds a "Start at
  label position" stepper (1…cells/sheet, resets when the format changes),
  and the choice is per-print — never persisted.
- **DL17 — Reset is one transaction.** `resetCatalogAndReseed` now deletes
  and reseeds inside a single write (`Seeder.seedIfNeeded(_:)` is callable
  within an existing transaction; the bootstrap wrapper is unchanged). No
  observer ever sees a half-empty catalog, and the reset no longer blocks a
  cooperative thread on a synchronous write.
- **DL18 — Scan lookup failures surface in the viewfinder.** A thrown DB
  read in `ScanView.handle` now shows the overlay card's error variant
  ("Couldn't look that up — try again") instead of only logging — the
  scanner never dies silently.

## Questions for Owen — all five resolved 2026-07-17

1. **Seed room list — resolved.** Owen's 12-room list shipped (DL15):
   Kitchen, Living Room, Office, Master Bedroom, Master Bedroom Closet,
   Andrew's Closet, Michael's Closet, Garage, Basement, Shed (Upper Door),
   Shed (Upper Back), Laundry.
2. **Seed category list — resolved.** Approved as-is (11 categories,
   unchanged).
3. **Label sheet stock — resolved (purchase still open).** Both presets stay;
   5163-style remains the default. Owen hasn't picked a stock — he'll buy
   what fits. Note for that purchase: the 5160 preset geometry matches the
   real Avery template exactly; the 5163 preset is approximate. Either way,
   print one sacrificial calibration sheet and eyeball alignment before a
   real batch (device-only step).
4. **iPad — resolved.** iPhone-only for now approved, but iPad is *planned*,
   not parking-lot: M6 scope now includes iPad support
   (`TARGETED_DEVICE_FAMILY = 1,2` + layout pass); target device is
   Shelley's iPad (iPadOS 27 beta — runs an iOS 26-target app fine).
5. **Reprint onto partially-used sheets — resolved and shipped** (DL16):
   per-print "Start at label position" control on the label sheet screen.

### 2026-07-18 — M0/M1 gate closed

- **Owen's on-device pass passed; M0/M1 are done. M2 (private-zone sync) is
  next** — it starts with the CloudKit Development env reset in the Console
  (Owen's one click) and the DatabasePool switch below.
- **DL19 — Item-editor "can't type" report was the OS, not the app.** An
  on-device typing freeze (dead keyboard ~30 s, then stalls) was
  investigated: with input frozen, the app's main thread sampled fully idle
  (keystrokes never reached the process), the same stall reproduced in the
  system Settings app, and the editor path does no work during typing. Root
  cause: iOS 27 developer beta 3's known keyboard bugs (Owen's phone).
  Standing rule, same as plan M4: device weirdness gets cross-checked on a
  stable-OS device before suspecting app code. Also noted: freshly created
  simulators are unusably laggy until rebooted after first-boot indexing —
  don't judge app behavior in one.

### 2026-07-18 — Run 2 (M2, private-zone sync)

- **DL20 — Two write paths, two context types.** All user-driven writes go
  through `AppDatabase.performLocalMutation` (`LocalMutation`: stamps
  `updated_at` and enqueues `pending_changes` in the same transaction);
  inbound sync goes through `AppDatabase.applyServerChanges` (`ServerApply`:
  applies rows verbatim, no restamp, no outbound echo). Distinct types, not a
  flag, so the paths can't be confused. Repositories, Seeder, and catalog
  reset all ride the local path; local-only `settings` writes stay plain
  (nothing to stamp or queue).
- **DL21 — "Untouched since last ack" = no pending row.** The LWW merge
  takes (local `updated_at`, pending change, server `updated_at`) — the v1
  schema needs no per-record last-ack column because `pending_changes` rows
  exist exactly while a local edit is unacked. Ties keep local (both sides
  re-sending converges on the last upload; the loser then has no pending row
  and accepts the fetch). A queued delete's `queued_at` is its edit time.
  Server deletions beat in-flight local edits (both for inbound deletes and
  `unknownItem` on save) — logged, never silent.
- **DL22 — Deletes enqueue children explicitly, metadata clears on ack.**
  Room/container cascades queue item → container → room deletes before the
  local FK cascade runs. Category deletes first re-save affected items with
  the reference cleared (tracked saves) — relying on `SET NULL` alone would
  leave server items pointing at a dead category and FK-break a fresh
  device's M3 bootstrap. `record_metadata` survives until the delete acks,
  so reset's delete→reseed collapse (same fixed UUIDs, REPLACE turns the
  queued delete back into a save) overwrites server records with valid
  change tags instead of conflicting.
- **DL23 — The engine's in-memory queue is rebuilt from `pending_changes`
  via ValueObservation.** Repositories never talk to the coordinator; every
  commit that touches the queue re-adds the rows to `CKSyncEngine.state`
  (idempotent), and rows are cleared only on server ack — with a
  stamp-comparison guard so an edit made while its save was in flight stays
  queued. Startup re-adds whatever the last run left behind.
- **DL24 — Inbound FK orphans are buffered, not dropped.** CloudKit fetch
  batches don't respect parent-child order, so saves apply parents-first per
  batch and FK failures wait in a coordinator buffer, retried after each
  batch and once more when the fetch completes; then an item missing only
  its category is salvaged without the reference, and anything whose parent
  is genuinely gone is dropped with a log.
- **DL25 — Account lifecycle.** The engine exists only while
  `accountStatus == .available`. Sign-out stops sync and keeps data plus
  bookkeeping (the same user signing back in resumes cleanly). An account
  *switch* (detected by comparing the stored `userRecordID` at startup, or
  the engine's switchAccounts event) resets engine state + `record_metadata`
  — never the catalog, and `pending_changes` survives — then backfill
  re-queues everything for the new account. Zone deleted / purged /
  `zoneNotFound` → wipe metadata, drop queued deletes, recreate the zone,
  re-backfill (single-flight guard; the engine's own send scheduling paces
  retries).
- **DL26 — Simulators don't reliably get CloudKit pushes**, so the
  coordinator also fetches on scene-activation — which is what makes the M2
  two-device gate (iPhone ↔ simulator) observably snappy. Devices still get
  real pushes; `registerForRemoteNotifications` runs at startup and
  CKSyncEngine handles the notifications itself.
- **DL27 — In-sim no-account verification (gate prep).** On the signed-out
  simulator: Settings shows "Sync — Off (no iCloud account)", the on-disk
  store runs in WAL (`DatabasePool` conversion of the M1-era file verified),
  and a full UI catalog reset queued exactly the expected outbound rows
  (item delete before container delete; 12 room + 11 category saves for the
  re-seeded fixed UUIDs) with no engine running and no errors. Also
  reconfirmed: idb-injected keyboard input is flaky on the iOS 26.5 sim
  (DL19 family) — taps are reliable, typed text sometimes never lands.

### 2026-07-18 — M2 gate closed

- **Owen's single-Apple-ID device pass passed** (two-way iPhone ↔ simulator
  sync, offline reconcile, forced conflict resolved LWW, Console shows the
  four record types in `Household`, relaunch resumes from serialized state).
  **M3 (zone sharing) is unblocked** — it starts with the Production schema
  deploy + environment pin (D15). Note: the iPhone 17 simulator is now
  signed into Owen's Apple ID and live-syncs the Development household data;
  it is no longer a throwaway sandbox.
- **DL28 — In-app sync activity log (Owen's feature request at the gate).**
  Conflict outcomes were only visible in Console.app on a Mac; family
  devices (M4+) won't have a Mac attached. Migration `v2` adds local-only
  `sync_events` (capped at 200 by `SyncEvent.append`); receipts are written
  where the decisions happen: LWW overwrites and delete-vs-edit drops
  inside the inbound transaction itself (`applyWithMerge` /
  `applyDeletion`), local-won receipts only for true send-conflicts
  (`serverRecordChanged`) so routine fetch echoes never spam the log, plus
  dropped-orphan, unreadable-record, and zone-rebuild receipts from the
  coordinator. Summaries are self-contained — they carry the row's name at
  event time, because the row may be gone by reading time. Settings → Sync
  Activity lists them newest-first with a Clear button; the full sync
  status surface remains M6.

### 2026-07-18 — Run 3 (M3, zone sharing)

- **DL29 — Roles + first-launch onboarding.** `SyncRole` (`.owner` /
  `.participant(zoneOwnerName:)`) persists in `sync_state`; a virgin database
  (no synced rows, no engine state/metadata/queue, no seed flag — the
  identity fingerprint deliberately doesn't count) gets the two-choice
  onboarding, and data-bearing installs predating roles auto-adopt `.owner`
  at launch. "Join a household" persists a join-pending settings flag (no
  role until acceptance) and shows a waiting screen with an explicit
  "Set Up This Home Instead" escape (confirmed via dialog). `Seeder` calls
  now exist only behind the owner branches (`AppBootstrap.becomeOwner`,
  catalog reset) — a participant device structurally cannot seed.
- **DL30 — Sync-identity fingerprint (generalizes DL25).** `sync_state` now
  stores (userRecordName, environment); a mismatch of either resets engine
  states + `record_metadata` + buffered orphans — never the catalog,
  `pending_changes` survives — then backfill re-queues. The environment
  component is the compile-time `CLOUDKIT_ENV_PRODUCTION` condition, defined
  in `project.yml` next to the `icloud-container-environment` entitlement
  with lockstep comments both ways. M2's account-only key migrates (assumed
  "development", so the first Production launch resets exactly once — one
  `sync_events` receipt, verified in-sim on the real store), and bookkeeping
  with no fingerprint at all is treated as stale. **Verified against the
  live container:** with the Production schema not yet deployed, every save
  fails with CKError 12/2006 "Cannot create new type … in production
  schema", rows stay queued, the app runs normally — Owen's Step 0 Console
  deploy unblocks the upload with no further action.
- **DL31 — Zone identity is resolved from the role, once.**
  `RecordMapper.zoneID` (hardcoded `CKCurrentUserDefaultName`) is gone;
  `SyncRole.zoneID` is the single source, threaded through
  `RecordMapper.record(for:systemFields:zoneID:)` and
  `PendingChange.enginePendingChange(in:)`. No call site constructs a zone
  ID ad hoc.
- **DL32 — Share record rides the plain database API, not the engine** (the
  brief's implementer's-choice note). Creation saves `CKShare(recordZoneID:)`
  via `modifyRecords` (zone re-saved first to kill the zoneNotFound race);
  the engine can't fight it because it only ever sends rows from
  `pending_changes`. Inbound, fetched CKShare records are intercepted before
  the catalog parser — they refresh the `participants` roster (and the
  owner's archived share copy in `sync_state`, which lets Family reflect
  sharing state offline/after relaunch); share *deletions* mean stop-sharing
  (owner: clear roster+archive) or revocation (participant: degrade).
- **DL33 — Acceptance decision table + ordering.** Fresh install and
  pristine-seed devices (rooms/categories exactly matching the seed, nothing
  else) join silently; anything else gets the "Joining replaces this
  device's catalog with the household's" dialog. Acceptance runs
  accept-first (`CKContainer.accept`, the async wrapper of
  `CKAcceptSharesOperation`): if the server call fails nothing local
  changed; the wipe + role adoption + roster seed then commit in one
  transaction (`ParticipantBootstrap.wipeAndAdopt`), so a crash leaves the
  device fully joined or untouched. Cold launches read the metadata from
  `UIScene.ConnectionOptions`; a model buffer covers metadata arriving
  before bootstrap finishes.
- **DL34 — Participants degrade; only owners recover zones.** Share revoked
  / removed / zone gone in participant role → engine off, catalog kept, a
  persisted disconnected flag (so relaunches don't re-fail), one
  `sync_events` receipt, persistent banner, and Family switches to
  rejoin-by-invite instructions. "Leave Household" deletes the `Household`
  zone from the participant's shared database (CloudKit's remove-self) and
  lands in the same state. The owner's zone-recovery path is unchanged and
  unreachable in participant role.
- **DL35 — created_by resolution.** Inbound parses stamp
  `creatorUserRecordID.recordName`; display resolves via the local roster:
  `__defaultOwner__` names the *zone owner* (owner device → "You";
  participant device → the owner's roster name), this device's own record
  name → "You", anything else → roster lookup or nothing. Shown subtly in
  container detail and the item editor footer. The both-sides rendering
  check is on Owen's gate.
- **DL36 — Orphan buffer persisted (closes the M2 review finding).** The
  in-memory FK-orphan buffer became the local-only `orphaned_records` table
  (v3): buffered in the same transaction as the batch apply, drained on
  coordinator start and after each fetch, cleared on apply/drop, salvage
  and drop receipts written inside the drain transaction. Undecodable
  payloads prune themselves.

- **DL37 — Permanent send failures must be visible and self-heal on
  foreground (post-gate incident).** Owen's first gate attempt stalled on
  "iCloud — syncing…" forever: the Production schema deploy hadn't actually
  landed (server kept answering CKError 12/2006 "Cannot create new type …
  in production schema"), every save stayed queued — correct — but (a) the
  status label only tracked "queue non-empty," so a dead end looked like
  progress, and (b) after a permanent failure CKSyncEngine drops those
  sends from its in-memory plan, so even a fixed server needed a force-quit
  before the app retried. Neither a catalog reset nor an app reinstall can
  help (both just rebuild the same queue) — worth remembering before
  reaching for either. Fixes: `permanentFailureMessage(for:)` classifies
  unretryable codes and `settleStatus` shows `.error` while such rows wait
  (cleared on the next send attempt); scene-activation re-adds
  `pending_changes` to the engine state, so "fix the Console → reopen the
  app" recovers with no relaunch. Queue rows are never dropped by any of
  this.

## Questions for Owen

*(none open)*

1. ~~**Reset Catalog semantics once the household shares the zone.**~~
   **Resolved (Owen, M3 kickoff): reset is owner-only.** Shipped in Run 3:
   participant role sees the Settings row disabled with "Only the household
   owner can reset the shared catalog."; a repository-level guard
   (`SettingsRepository.ResetNotAllowed`) backstops the UI. The owner keeps
   the "erases from iCloud for everyone" footer.

## Watch-outs for M2/M3 (from Run 1 review)

- ~~**DatabasePool at M2 start**~~ — done (DL27): `onDisk()` opens a
  `DatabasePool`, WAL conversion of existing stores verified in-sim; tests
  stay on in-memory `DatabaseQueue`.
- ~~**Participant seeding (D12)**~~ — closed structurally in Run 3 (DL29):
  seeding is owner-path-only by construction (onboarding decides the role
  before anything seeds; the acceptance path never touches `Seeder`), so no
  seed-flag ordering trick is needed at all.
- ~~**`updated_at` discipline**~~ — done (DL20): stamping lives in
  `LocalMutation.save` alone; repositories no longer touch timestamps.
- **Deferred cleanups** (deliberately not done without a compiler on hand):
  extracting the repeated observation-consuming `.task` loop into a helper,
  a shared editor-sheet scaffold for the four CRUD editors, and moving the
  count-annotated raw SQL onto GRDB associations. All are mechanical and
  safe to do on-Mac later; none block M1.

## Environment note — Run 1

Run 1 executed in a Linux container without Xcode/Swift. Schema DDL and
cascade behavior were proven against real SQLite (see VERIFY report);
`xcodegen generate` + build + test + simulator walkthrough happen on Owen's
Mac as the first `scripts/build.sh` / `scripts/test.sh` runs. Expect the
possibility of small first-build fixups; everything else is in place.
