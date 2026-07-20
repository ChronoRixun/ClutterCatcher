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

- **DL38 — `cloudkit.share` is schema too (second gate incident).** After
  the record types deployed and sync settled, share creation failed on
  whoGoesThere. Reproduced identically on the stable-OS simulator (DL19
  rule: not the beta) with the real error: CKError 12/2006 "Cannot create
  new type **cloudkit.share** in production schema". The share record type
  is created just-in-time in *Development* the first time a share is saved
  there — and M3 never exercised sharing in Development, so the Step 0
  deploy carried the four record types but no share type. Recovery: a
  temporary Development-pinned build (entitlement + compile condition
  flipped together, never committed) created one zone-wide share in Dev via
  the app's own Family flow — JIT-creating the type — then the build was
  flipped back; the sync-identity fingerprint absorbed both environment
  hops exactly as designed (reset → re-upload → LWW convergence, catalog
  untouched). Owen then redeploys the schema once. Rule for the future: a
  Production schema deploy is only complete after *every* record-producing
  flow has run once in Development — including sharing. Also: the Family
  screen's failure alert now names permanent causes instead of suggesting
  "try again" (extends DL37's classifier to share creation).

### 2026-07-19 — Run 4 (M6, item photos — cloud/uncompiled)

Slice of M6 per `planning/m6-photos-plan.md` (P1–P14). Cloud Linux container,
no Xcode/Swift — reviewed source, not a green build (see the Run 4 environment
note below; same precedent as Run 1).

- **DL39 — Photo files are keyed by `photo_asset_ref`, not the item id.**
  The plan's P8/P9 say "keyed off the item id / `Photos/<id>.jpg`", but §5/P7
  (authoritative on the file layout) say `Photos/<photo_asset_ref>.jpg`. Those
  conflict; the ref is correct — it's the device-independent photo id (P6) that
  changes on replace, so keying by it makes "replace" mint a new file and keeps
  the missing-file check honest. Read P8/P9's "id" as "the photo id."
- **DL40 — The inbound CKAsset copy is ONE seam, not two.** P8 (after apply)
  and P9 (before buffering) collapse into a single materialization step at the
  top of `handleFetchedRecordZoneChanges`, run before `applyServerBatch`: the
  asset `fileURL` is read off the live `CKRecord` there (temp URLs are valid
  only inside the delegate callback), and `PhotoStore.ensureLocalFile` copies by
  ref only when the file is missing. Because it's idempotent and keyed by the
  device-independent ref, one call covers both the applied case (file on disk
  before the row lands) and the orphaned case (file on disk before the buffered
  row is ever drained). Consequences: **`applyServerBatch` and
  `ParsedServerRecord` are untouched** (the critical, well-tested path stays as
  is), and the copy runs for every inbound photo'd item including LWW
  `keptLocal` — a near-total no-op there (this device authored the local
  version and already has the file), at worst one small unreferenced cache file.
- **DL41 — Outbound attaches the CKAsset only when the local file exists, and
  never clears an asset it simply doesn't have.** The mapper takes a resolved
  `assetFileURL` (threaded from `PhotoStore.existingFileURL`, so `parse`/`record`
  stay pure). If the ref is present but the bytes aren't on this device, `photo`
  is left untouched — a metadata-only edit from such a device must not nuke the
  household's asset. The real "photo removed" signal is `photo_asset_ref = nil`
  (always sent); a stale CKAsset behind a nil ref is unread and harmless.
  Trade-off accepted: the asset re-uploads on every item edit (the plan's
  "attach when a file exists" wording); a "only re-attach when the ref changed"
  optimization is deferred (needs extra state).
- **DL42 — Photos are encoded JPEG ~0.8 with `.jpg` filenames, not HEIC.**
  P12 lists HEIC preferred / JPEG fallback, but §5/P7 name the files `.jpg` and
  that layout is load-bearing (the id→path contract). The on-disk file is a
  regenerable cache and doesn't touch the sync contract (P6 ref is
  device-independent), so JPEG-in-`.jpg` is the low-risk, self-consistent
  interim. HEIC is a size optimization → Question for Owen.
- **DL43 — Editor stages photo on Save; cover applies immediately.** The chosen
  `photo_asset_ref` is staged in the editor and committed with Save like every
  other field, so cancelling discards a fresh capture and never disturbs the
  existing photo. "Set as Container Cover" edits the *container* (`cover_item_id`
  via the local-mutation path) and applies immediately. A cleanup ledger
  (`sessionRefs` + `originalRef`) deletes replaced/intermediate files at commit
  and only the uncommitted captures on cancel — no leak on the common path.
- **DL44 — Local photo-file cleanup is UI-layer; inbound/cascade stale files
  are tolerated.** Replace/remove/delete in the editor and swipe-delete in
  container detail delete the local files (§4). Peer-side replace/delete and
  container/room *cascade* deletes do **not** eagerly delete this device's
  cached files — a bounded, non-correctness cache leak (P13 makes missing/stale
  first-class) reclaimed by Reset Catalog. Kept the critical delete/merge paths
  untouched rather than thread refs through every cascade.
- **DL45 — `PhotoStore` injection.** A `Sendable` value type over a `Photos/`
  root, injected via `@Environment(\.photoStore)` (temp-rooted default for
  previews). The coordinator resolves its own `PhotoStore.onDisk()` at the same
  real root — so the `SyncCoordinator(database:status:)` init signature is
  unchanged and `OrphanPersistenceTests` is unaffected.
- **DL46 — No `project.yml` change.** The app target globs the whole
  `ClutterCatcher/` directory, so `Shared/PhotoStore.swift` and
  `Features/Items/ItemPhotoViews.swift` are picked up automatically;
  `xcodegen generate` on the Mac still regenerates the project. No plist change
  (`NSCameraUsageDescription` already ships for the scanner).
- **DL47 — Migration v4.** `ALTER TABLE containers ADD COLUMN cover_item_id
  TEXT` — additive, nullable, no backfill, no item migration; `cover_item_id`
  is a SOFT reference (no FK — a hard container→item FK would cycle against the
  verified parents-first order). `items.photo_asset_ref` already existed (v1);
  M6 only defines its meaning (P6).
- **DL48 — Branch.** Developed on `claude/item-photos-m6-1eeil1` (the harness's
  designated branch for this run), not the `feat/item-photos` named in the
  kickoff doc. Same content; Owen can rename/re-target locally if he prefers.
- **DL49 — Send-conflict adopts a server photo → pull for its bytes.** In
  `resolveConflict`'s `.applied` branch (a `serverRecordChanged` where the
  server edit wins), the new `photo_asset_ref` is adopted but the conflicting
  record carries no downloaded CKAsset (its `fileURL` is nil), so the peer
  would show the P13 placeholder until an unrelated sync. Added a `fetchSoon()`
  there (mirroring the `.orphaned` branch) so a real record fetch re-downloads
  the adopted photo promptly. Surfaced by the Run 4 self-review; self-heals via
  P13 regardless, so low-risk. (Same review confirmed the cover SQL,
  P8/P9/P11, mapper purity, and the editor photo lifecycle are correct.)
- **DL50 — M6 Production deploy went Console-manual; DL38's rule strengthened
  (2026-07-19, merge-day).** The photo/cover schema deploy skipped the DL38
  entitlement-flip ritual entirely: fields were added by hand in the Console's
  Development schema (`Item.photo` Asset, `Container.cover_item_id` String) and
  deployed — manual creation satisfies the same invariant JIT creation would.
  First attempt still failed with the DL37 "schema not deployed" alert, which
  exposed the real lesson: **five nullable fields had never JIT-created in
  Production** because a nil write creates nothing — `Item.photo_asset_ref`,
  `Item.notes`, `Item.category_id`, `Container.notes`, `Container.label_slot`
  were all absent (no note, category assignment, or label print had ever synced
  non-nil there). All five added and deployed in a second pass. **DL38's rule is
  hereby strengthened: a deploy is complete only when every field the mapper can
  emit has been written NON-NIL once in Development (or created manually) —
  "every record-producing path ran once" is not sufficient.** The durable queue
  behaved exactly as designed throughout: the photo'd save survived both
  rejections and landed on foreground after the second deploy, no data loss.
  First live cross-account CKAsset verified same day: photo set on Owen's
  device, appeared on Shelley's.

### 2026-07-19 — Run 5 (M6.1, HEIC + photo cache GC — local Mac, green build)

Slice per `planning/m6.1-heic-gc-plan.md` (P15–P20). Local-only; no schema
change, no migration, no CloudKit deploy; the DL20 write paths untouched (the
GC's database access is read-only). Built and tested on Owen's Mac under
stable Xcode 26.6 — `scripts/test.sh` green, 166 tests / 20 suites (three new:
PhotoEncodingTests, PhotoSweepTests, LivePhotoRefTests; the M6-era
PhotoStoreTests pass unchanged, as P16 promised).

- **DL51 — HEIC switch (closes Run 4 question 1; supersedes DL42's interim).**
  `PhotoStore` encodes through one internal `encode(_:)` seam used by full
  image and thumbnail alike (P15/P17): `CGImageDestination` with
  `UTType.heic` and lossy quality 0.8 — `UIImage.heicData()` has no quality
  parameter — falling back to `jpegData` when HEIC fails or is skipped. A
  `preferredEncoding` init parameter (default `.heic`) is the injection seam
  the fallback test uses; `jpegQuality` renamed `encodingQuality` (was
  PhotoStore-internal only). File names stay `Photos/<ref>.jpg` /
  `<ref>_thumb.jpg` regardless of encoding (P16, documented on
  `fileURL(for:)`: ".jpg means image file"); no lookup changes, no migration,
  mixed JPEG/HEIC caches coexist. The encode test's container-format
  assertion is gated on `isHEICEncodingAvailable`
  (`CGImageDestinationCopyTypeIdentifiers`, §4's CI caveat) with the decode
  round-trip as the unconditional floor — and a throwaway probe confirmed the
  encoder IS present on the iPhone 17 / iOS 26.5 simulator, so the HEIC
  assertions genuinely ran in this suite, not just the gate.
- **DL52 — Sweep semantics the plan's words left open (P18/P19).** (a) The
  1-hour age guard is enforced **per pair, not per file**: a pair is deleted
  only when *every* file of it predates the cutoff, so one fresh file
  protects its sibling — deleting a full image out from under a fresh thumb
  (or vice versa; `regenerateThumbnailIfNeeded` can freshen just the thumb)
  would tear exactly the pair the guard exists to protect. Satisfies P19's
  "skip any file within the hour" and strengthens it. (b) Every `*.jpg` in
  `Photos/` parses as `<ref>[_thumb].jpg` with no UUID-format validation —
  inbound refs are opaque peer-minted strings and the directory is wholly
  PhotoStore's; non-`.jpg` files are never touched; an unreadable
  modification date counts as fresh (skip). A stray thumb with no full still
  sweeps. (c) `sweepUnusedPhotos` never throws: a missing `Photos/` dir is a
  zero result, and per-file removal failures are logged and skipped (P20 — a
  leftover file is the status quo, not a fault). Note the age guard is doing
  real correctness work, not just editor-safety: DL40 materializes inbound
  asset bytes *before* the row lands, so a concurrent live-set read can't see
  that ref yet — but that file is seconds old, and the guard covers it.
- **DL53 — Live set assembled read-only; sweep runs off-main from Settings.**
  `SettingsRepository.livePhotoRefs()` returns DISTINCT non-nil
  `items.photo_asset_ref` ∪ refs of Item rows decoded from
  `orphaned_records` (P18 — covers, via item ids, container covers too). It
  deliberately does **not** use `OrphanedRecord.loadAll`, which prunes
  undecodable rows and needs a write connection — this read prunes nothing
  (test-asserted), keeping the whole slice off the DL20 write paths.
  Undecodable orphans contribute no refs; their bytes are sweepable (the
  drain could never apply them either). SettingsView runs the sweep in a
  detached task with cutoff `now − PhotoStore.sweepAgeGuard`; if the live-set
  read itself fails there is **no** sweep at all (never guess at what's
  referenced) and the footer shows a non-alarming "Couldn't clean up right
  now." Success reports "Removed N files, freed X MB" / "Nothing to clean
  up." transiently in the section footer (P20).

### 2026-07-19 — Run 6 (M4a, ThemeKit + Make It Yours — local Mac, green build)

Slice per `planning/m4-themes-plan.md` §7 (M4a). Local-only per T2: no schema
change, no migration, no CloudKit surface — `Sync/` untouched, theme state is
a plain `settings` write, and the required zero-`pending_changes` test is in.
Built and tested on Owen's Mac under stable Xcode 26.6 — `scripts/test.sh`
green, 178 tests / 21 suites (one new: ThemeTests, 12 tests). M4b (motion
personality, ear-perk, peeks, pixel sprite, confetti) not started, per the
kickoff.

- **DL54 — ThemeKit shape.** `Theme`/`Palette` are plain hex-valued data
  (`Design/Theme.swift`); views resolve colors through dynamic
  `UIColor { traits in … }` bridges so every theme follows the system
  light/dark setting with zero `preferredColorScheme` (T4). Classic is a
  *structural* no-op: `themedScreen()`/`themedRow()` short-circuit on
  `isClassic` and its root tint is nil, leaving the asset-catalog AccentColor
  in charge — pixel-equivalence isn't a matching palette, it's untouched
  code paths. Palette role fallbacks (T3) are baked into the definitions
  where the sheet names them (Pop! success → accent2, Fresh success →
  accent); `Palette.hex(for:)` covers the rest (accent3 → accent2 → accent).
  Note: navigation-bar large titles keep the system (non-rounded) font — T5's
  "system bars keep native treatment" wins over the mockups' rounded titles;
  content type is rounded via one root `.fontDesign(.rounded)` (T6).
- **DL55 — T7's build setting is spelled differently in Xcode 26.**
  `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_NAMES` (the plan's name) is
  silently ignored — nothing warns, the alternates just never compile.
  The live setting is `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`
  (verified in `AssetCatalogCompiler.xcspec`; maps to actool's
  `--include-all-app-icons`). A test asserts every alternate icon name is
  registered under `CFBundleAlternateIcons` in the built Info.plist, so this
  can never silently regress. The picker's tiles use duplicate preview
  imagesets (`IconPreview-*`, ~350 KB total) because alternate appiconsets
  aren't loadable via `Image(named:)`.
- **DL56 — Fen's in-app Pop! colors come from the empty-state mock, not the
  icon glyph.** `design/fen-geometry.md`'s Pop! row (cream body) describes
  the *Fen Wink icon*, which sits on a pink gradient tile; on Pop!'s own
  cream background a cream Fen vanishes (verified in-sim). The Pop Lead
  Screens empty-state card (1e) draws Fen with the tangerine body
  (`#FF8A3B`), so `Theme.pop.fenColors` uses that. Cozy and Arcade rows
  translate as-is (their icon backgrounds match their theme backgrounds).
  Same card confirmed the geometry doc's shape coordinates exactly.
- **DL57 — Scan-success card semantics (§4).** An in-app container scan now
  shows the "Found it!" card instead of navigating immediately; "Open It Up"
  does the DL5 stack-replacing navigation. Camera-app deep links never pass
  through ScanView, so they still navigate directly, and room scans (r/
  payloads, unprintable today) keep the immediate jump — the card is a
  container concept in the design. Two judgment calls: a quiet "Scan Again"
  button rides under "Open It Up" (the scanner pauses behind the card, so
  a wrong-bin scan needs an escape the mock doesn't show), and in the
  manual-entry fallback the result card takes the *top* slot — replacing the
  "camera unavailable" notice — because as a trailing Form section it
  rendered half-hidden behind the tab bar.
- **DL58 — Theme surface application covers the §8 touch-list screens
  only.** Rooms/RoomDetail/ContainerDetail/Scan/Search/Settings + both
  pickers get themed backgrounds and row surfaces; Family, Labels, 
  Categories, Sync Activity, and Onboarding keep system backgrounds under
  every theme in M4a (they still inherit the accent tint and rounded type,
  and sheets keep native treatment by design, T5). Interim answer chosen as
  most reversible — extending `themedScreen()`/`themedRow()` to a screen is
  a two-line change. Flagged as a Question for Owen for the M4b scope.
- **DL59 — Two presentation-timing fixes from the simulator pass.** (a) The
  theme picker's "use the matching icon?" offer is presented only *after*
  `ThemeStore.select` returns — setting the dialog flag in the same
  transaction as the theme-change re-render got the presentation silently
  dropped. (b) The App Icon picker reads
  `UIApplication.shared.alternateIconName` live at render (with a bump token
  after changes) — the original one-shot `.task` snapshot returned nil on
  the iOS 26.5 sim even with an alternate icon active, ringing the wrong
  tile. Both verified in-sim after the fix; neither is testable in the
  hosted suite (presentation + system icon state).

### 2026-07-19 — M4a gate closed

- **Owen's on-device pass passed** — the branch build installed on both
  phones; themes verified working and confirmed as **independent per-device
  choices** (the T2 zero-sync-surface guarantee held in the wild, Sync
  Activity quiet). `feat/themes-m4a` merged to `main` (`--no-ff`, 965b068).
  The redundant repo-root `cc-m4-design-assets.zip` and
  `icons_contact_sheet.png` (never tracked; `design/` is the committed copy)
  were deleted. **M4b (motion + Fen personality + the family gate) is next**
  — kickoff at `planning/m4b-kickoff-prompt.md`; dispatch on
  `feat/motion-m4b` off `main`. The DL58 coverage question below gates part
  of its scope.

### 2026-07-19 — Run 7 (M4b, motion & Fen personality — local Mac, green build)

Slice per `planning/m4-themes-plan.md` §6/§7 (M4b). Zero sync surface held by
construction and by measurement: no schema, no migration, `Sync/` untouched,
and a live-sim session (theme flips, six scan-card presentations, Reduce
Motion toggles, eight relaunches) left `pending_changes`/`sync_events` counts
byte-identical (23/0 → 23/0) alongside the M4a zero-`pending_changes` test.
Built and tested under stable Xcode 26.6 — `scripts/test.sh` green, 185
tests / 22 suites (one new: MotionTests, 7 tests). The DL58 coverage
question was still open at run time, so themed-surface coverage ships
unchanged (touch-list only) and the question stands.

- **DL60 — Motion tokens are values hung off Theme; Reduce Motion is a
  parameter, not an afterthought.** `Design/Motion.swift`: `SpringSpec`
  (response/damping as plain data) and `MotionPersonality` (settle +
  card-entrance specs, scan/save reward styles) mirror how palettes work.
  A nil spec means system default — motion's structural no-op, matching
  Classic's theming no-op (Dusk's card entrance is nil too; its
  "standard transition" reads as "unchanged"). Resolution takes
  `reduceMotion:` explicitly: every animation collapses to one plain fade
  and both reward styles collapse to `.standard`, so a single switch per
  call site covers both variants. `@Environment(\.accessibilityReduceMotion)`
  is the production source, the parameter is the test seam (§7's
  flag-flips-the-implementation test).
- **DL61 — Scan-card personality per §6; DL57 semantics untouched.**
  ScanSuccessCard owns the reward moment: Pop! bouncy entrance (the literal
  `response .35, damping .6`) + one-shot confetti + Fen peek with the wink
  as the settling flourish; Arcade glow-breathing (twice, then settles low)
  + `numericText` score-tick count-up; Fresh trim-drawn leaf beside the
  container line; Cozy's soft settle is the entrance spring itself.
  Judgment calls: under Reduce Motion Fen still peeks — presence is theme
  identity, not motion — but arrives settled with the fade and never winks;
  leaf/count-up/glow simply don't run (style collapse); Camera-app deep
  links still bypass the card (DL57), so the scan-found haptic lives in the
  card's per-presentation task.
- **DL62 — Confetti is KeyframeAnimator-driven shape views, not
  Canvas/TimelineView; burst state lives in ScanView.** The kickoff's
  Canvas+TimelineView burst silently draws nothing inside a List row on the
  pinned iOS 26.5 sim runtime — verified stepwise: the view inserts and
  `onAppear` logs, the canvas never renders (as a ZStack sibling it also
  collapses to zero height; an `.overlay` fixed sizing and it *still*
  drew nothing). Plain `Circle`s animated per-dot by `keyframeAnimator`
  (t → parabolic flight in the closure) are the same machinery the rest of
  the moment uses and render everywhere. Two survival rules learned on the
  way: (a) the one-shot guard AND the in-flight burst id must both live in
  ScanView — the card row gets torn down and recreated around the
  keyboard-collapse/section-swap moment, and card-local state died having
  consumed the guard, eating the burst; (b) the toss waits ~300 ms for the
  entrance to land — it reads better and stops the burst's wall-clock life
  racing a lagging first frame (seen clearly under recording load).
- **DL63 — Save reward + haptics (T10).** Soft-impact haptic on the save
  path of all four editors; success-notification haptic on scan-found —
  every theme, Classic included, and deliberately not gated on Reduce
  Motion (haptics aren't motion). Pop!'s drop-in squash-settle is an
  insertion transition on the container item rows plus a theme-settle
  animation on item-list changes; Classic's list animation is nil
  (pre-M4b behavior untouched). Honest caveat: the squash-settle was not
  visually verified in-sim — the capture sandbox deliberately took zero
  catalog writes — so it rides Owen's device gate (VERIFY human #1), with
  DL62's List-transition lesson as the known risk if it doesn't read.
- **DL64 — Fen behaviors (§5 M4b).** Ear-perk (~4°, ears pivot at their
  base midpoints, tips outward) triggers on the empty-state primary
  buttons of Rooms home *and* RoomDetail — the same "Add Your First Room"
  pattern — for Cozy and Pop! only, per the kickoff's theme list (the
  Arcade sprite doesn't perk). The perk plays under the presenting sheet;
  accepted rather than delaying navigation per-theme. The wink swaps the
  right eye for the geometry doc's stroked arc (pre-stroked path so width
  scales); placement judgment: post-reward flourish on the Pop! peek only —
  no other placements this run. The pixel variant ships exactly per
  fen-geometry.md (rect eyes/nose, no highlights, blink squashes the
  rects), with the accent glow as a compositing-group shadow scaled by a
  GeometryReader; Arcade's Scan presence is the sprite above the
  viewfinder hint and in the manual-path notice.
- **DL65 — Cross-cutting polish.** Rooms first-load stagger: once per
  launch via a process-lived flag, decided inside the observation loop
  before the first non-empty render (no flash on later visits), 30 ms/row
  capped at row 15, theme settle spring; Reduce Motion = one plain fade,
  no offset, no stagger. Icon-picker tile bounce: fires only after
  `AppIcons.apply` returns (DL59's timing lesson), rides the theme's
  settle spring, suppressed under Reduce Motion.
- **DL66 — DEBUG capture harness + sim capture playbook.** ScanView gained
  an env-gated, DEBUG-only auto-scan hook (`CC_AUTOSCAN_CODE` /
  `CC_AUTOSCAN_DELAY` via `SIMCTL_CHILD_*`) after DL27's typing flakiness
  turned manual-entry capture runs into a lottery (pasteboard and
  host-keystroke routes all proved intermittent). Two sim facts worth
  keeping: ScanView's `.task` runs at *launch* (iOS 26 TabView
  materializes tabs eagerly), so the delay counts from launch, not tab
  visit; and `simctl recordVideo` drops animation samples under load —
  screenshot bursts (and AVAssetImageGenerator extraction when video does
  cooperate) are the reliable evidence path.

### 2026-07-19 — M4b device pass; merged. M4 gate remains OPEN

- **Owen's on-device pass passed** — branch build installed on both phones;
  motion looks good, including the two sim-unverifiable items DL63 flagged
  (Pop!'s save squash-settle, Arcade's count-up). `feat/motion-m4b` merged
  to `main` (`--no-ff`, 95f1c0a) so the remaining gate runs on the real
  build. **M4 is NOT closed yet** — still owed (plan §7, VERIFY human):
  the offline conflict script with receipts in both phones' Sync Activity
  (DL28), the one-week parallel-use soak on themed builds (DL19
  stable-device rule), and **Shelley's sign-off**. Sign-off closes M4 and
  opens M5 (Andrew + Michael, Arcade in hand).
- Note (Owen asked, 2026-07-19): Reduce Motion deliberately has **no
  in-app toggle** — it's the OS accessibility setting, honored per Apple
  convention; the theme picker is the app's motion dial. If a themed-look/
  calm-motion combination is ever actually wanted (likely candidate: the
  kids on Arcade at M5), an "animations" toggle in Make It Yours is
  trivial — every animation already resolves through the `reduceMotion:`
  seam, so an app flag just ORs in. Not built on speculation.

### 2026-07-19 — Run 8 (M7a, in-app polish — local Mac, green build)

Slice per `planning/m7-polish-plan.md` §3 (M7a): U1–U7 + the
`cluttercatcher://scan` route, under U11/U12. Zero schema, zero CloudKit
surface held by construction and by measurement: `Sync/` untouched, no
migration, no `project.yml` change, and a full sandbox-sim session (fresh
`CC-M7a-Sandbox`, never the live-syncing iPhone 17 sim) ended with
`pending_changes` at exactly seed + the four deliberate creations — the U2
move and U7 icon edit re-stamped their existing queue rows without adding
any (receipts in `artifacts/m7a/`). `sync_events` stayed 0; settings gained
only the local theme key. Built and tested under stable Xcode 26.6 —
`scripts/test.sh` green, **207 tests / 24 suites** (one new: PolishTests;
DeepLinkTests +7, RepositoryTests +3). The DL58 theming-coverage question
was still open at run time, so themed-surface coverage ships unchanged and
every new surface resolves through the existing seams (root tint, `.tint`,
`themedRow()`, the motion `settle` role; editors and pickers keep native
sheet treatment per T5).

- **DL67 — U4's threshold is "any container at all."** The only
  non-arbitrary boundary: the moment the first bin exists, the counts line
  has something true to say; before that, "12 rooms · 0 containers" only
  undersells. `RoomsSubtitle` is the pure, tested function; the aspirational
  line reads "Let's give everything a home — start by adding bins to a
  room." (echoing the empty-state title so the app speaks with one voice).
- **DL68 — A U2 move clears the source container's cover as a tracked
  save.** Moving out the item a container fronts would leave that
  container's `cover_item_id` dangling — display tolerates it (P10), but
  the old bin showing a photo of something no longer inside is visibly
  wrong. `ItemRepository.updateItem` detects the container change and
  clears the stale pointer in the same transaction, the P11 pattern, so
  peers converge too (tests pin: plain move = exactly one queue row; cover
  move = item + source container; rename ≠ move). In the editor, cover
  actions stay pinned to the *original* container — a staged, unsaved move
  can never re-aim "Set as Container Cover."
- **DL69 — U3 nudge mechanics.** `LabelNudgeState` is pure, tested state
  (created → offer, edit → never, newest creation replaces, dismiss →
  gone); the editor reports through a new `onSaved(_:created:)` seam. Two
  judgment calls: the offer is *view-lived* (leaving the room forgets it —
  "no persisted state" taken literally), and the print flow clears it on
  the label sheet's **dismissal**, not its presentation — clearing the row
  in the same transaction that presents the sheet is exactly the DL59 race.
  Verified live in-sim: create → nudge → Print opens the sheet with the
  container preselected; X dismisses; both paths one-shot.
- **DL70 — U6 is words plus one hierarchy step.** Empty rooms say "No bins
  yet" in `.tertiary` (populated rows keep "N containers" `.secondary`).
  Hierarchical styles derive from context, so the treatment holds across
  all twelve palettes with zero per-theme values; a tappable "Add a bin"
  affordance was considered and dropped — the row already navigates to a
  screen whose empty state is that button.
- **DL71 — U7 icon set + ring.** `Tokens.roomIcons` grows 15 → 24 curated
  household symbols (rooms → garage/outdoors → workshop → storage →
  hobbies; all present by iOS 16). Selection is a `.tint` ring — the M4a
  app-icon picker's marker — instead of the old filled tile, and every tile
  sits on a tinted wash so the grid follows each theme's accent, Classic
  included. `Room.displayIcon` centralizes the nil fallback the DB keeps
  honest. A test resolves every name via `UIImage(systemName:)` — a typo'd
  symbol fails silently at render time (the DL55 lesson, applied to
  symbols).
- **DL72 — U1 torch ships, its hardware half unverifiable here.**
  `TorchModel` (visibility + DL11 reset rules, tested) is separate from
  `Torch` (the device-lock `torchMode` seam) — the standard technique
  alongside `DataScannerViewController`, which owns its session and
  exposes no torch API. The sim has neither camera nor torch, so
  *coexistence could not be exercised in this run* — it rides Owen's
  garage VERIFY, honestly flagged. Discipline extended past DL11: the
  torch turns off on tab switch, result card, scene backgrounding, and
  representable dismantle. If the scanner fights the lock on device, the
  fallback is dropping the button — visibility logic and the isolated
  hardware call make that a two-line change.
- **DL73 — The scan route is a tab selection, nothing more.** `DeepLink`
  (`.catalog(Route)` / `.scan`) wraps the existing Route parsing;
  `Router.open` switches on it. "Exactly as a tap would" is test-pinned:
  `selectedTab = .scan`, catalog stack untouched, no rejection alert.
  Verified live via `simctl openurl` (through the system's "Open in
  ClutterCatcher?" confirmation).
- **DL74 — Sandbox-sim field notes (extends DL19/DL27/DL66).** (a) Shutting
  a freshly created simulator down during/just after first-boot indexing
  can wedge backboardd's event dispatch: frames keep rendering (clock
  ticks) while *all* input is dead — idb HID, host-window clicks, even
  Simulator.app's Home command — which masquerades as idb flakiness; a
  clean shutdown/boot cures it. (b) On this fresh 26.5 sim every
  text-injection channel failed (idb `ui text`, HID key-sequence, host
  hardware-keyboard typing, `simctl pbcopy` timed out) while *touches*
  stayed reliable — tap-typing on the software keyboard (⌘⇧K to disconnect
  the hardware keyboard first) is the dependable path. (c) `simctl io
  screenshot` can trail the UI by a frame or two — sequence automation on
  DB state, not pixels.

### 2026-07-20 — M7a gate closed

- **Owen's on-device pass passed** — built from the branch, no issues on
  the test run, including the one thing the sim couldn't prove: the torch
  coexists with the live scanner session (DL72's flagged risk didn't
  materialize). `feat/polish-m7a` merged to `main` (`--no-ff`, 537346a);
  the merge also lands the deep-review planning docs (U13/U14, M6/M8
  amendments, the M6.2 iPad kickoff) that rode the branch base. **M7b
  ("the house that knows": U8–U10 + U13–U14) is M7's remaining dispatch**
  — its kickoff gets written at dispatch time. M4's human gate (conflict
  script + soak + Shelley's sign-off) still runs on wall-clock time in
  parallel.

### 2026-07-20 — Run 9 (M4c, themed-surface completion — local Mac, green build)

Slice per `planning/m4c-kickoff-prompt.md`, implementing Owen's DL58
resolution (theme everything; Onboarding stays system). Zero schema, zero
sync surface held by construction and by measurement: `Sync/` untouched, no
migration, no `project.yml` change, and the full sandbox-sim capture session
(CC-M7a-Sandbox, never the live iPhone 17 sim) ended byte-stable —
`pending_changes` 27 → 27, `sync_events` 0 → 0, label slots 0 → 0, catalog
untouched; settings gained only the theme-key flips the captures required
(receipts in `artifacts/m4c/final-accounting.txt`). Built and tested under
stable Xcode 26.6 — `scripts/test.sh` green, 207 tests / 23 suites,
unchanged (view-layer only, as the kickoff expected). Does not disturb M4's
human gate (soak continues; Shelley's sign-off still closes M4).

- **DL75 — The four screens ride the M4a seams unchanged; the PDF preview
  desk is the one new seam.** Family, Labels, Categories, and Sync Activity
  get `themedScreen()`/`themedRow()` exactly like the §8 touch-list screens
  (Classic short-circuits structurally, T5 sheet chrome stays native). The
  label preview keeps its white page on a themed desk: the *page* is
  PDFKit's paper rendering (untouched); the *desk* is
  `PDFView.backgroundColor`, set through new `Theme.uiColor(_:)` — the same
  dynamic light/dark `UIColor` bridge `color(_:)` already used (DL54),
  now exposed for UIKit-backed surfaces — and left at PDFView's default
  when Classic (nil = the structural no-op extended to UIKit). Verified in
  Arcade dark (the watch-for: white page, indigo desk) and Cozy light (the
  harder light case: the page still reads against a cream desk). Editor
  sheets were checked next to their newly themed parents (category editor
  over themed CategoriesView, Cozy light): they present full-height with
  system background + theme tint, identical to every M4a editor — no
  clash, untouched per the kickoff's judgment rule.
- **DL76 — Evidence accounting (what "zero deltas" actually measured).**
  (a) Classic no-op: four screen pairs main (418e097) vs branch, same sim,
  same navigation, status bar pinned 9:41, compared as uncompressed BMP
  bytes — every difference is simulator chrome, not app content: Dynamic
  Island compositing (renders in some frames, not others), Liquid Glass
  toolbar blur/specular sampling (≤2-value noise for ~90% of differing
  pixels), one 124×5 px tab-bar blur strip. Zero content-region deltas.
  (b) The two PDF generates are the label feature's normal DL7 slot
  assignment — bracketed: DB snapshotted (app terminated), generate +
  capture, restore; both restores verified 27/0/0. Observed en route:
  the slot write re-stamped the container's existing queued row
  (`pending_changes` stayed 27) — the M7a re-stamp behavior again.
  (c) Navigation sweep, Arcade dark: 21 burst frames across all tab flips
  and sheet present/dismiss; every frame mean-luminance 39–49/255,
  near-white ≤0.2% — no flash-of-system-background. (d) Severity colors:
  sandbox has zero `sync_events`, so the rows were checked numerically —
  dark-mode ratios ≥3.64 everywhere (Arcade dark, the flagged case, is
  the *best* case), light-mode yellow/orange/green sit below the 3.0
  graphics bar *against white surfaces*, i.e. the pre-M4 Classic status
  quo, unworsened by theming; rows carry text summaries, and the finding
  feeds M6's accessibility audit. Category dots verified visually on
  Pop! dark / Arcade dark / Cozy light — legible.
- **DL77 — Sim-automation field notes (extends DL74).** (a) The xclaude
  plugin's MCP swipe gesture on this 26.5 sim times out at the tool layer
  but *executes late*, leaving stuck touch state that silently swallows
  subsequent toolbar-area taps while row and tab-bar taps keep working —
  a nasty misdiagnosis trap (it looks like "toolbar buttons are broken").
  DL74's cure applies: clean shutdown/boot. The `idb` CLI (`idb ui swipe`)
  completes synchronously and was reliable all session — used for every
  scroll after the reboot, a deliberate deviation from the plugin skill's
  MCP-only rule, since the MCP path was demonstrably leaving incomplete
  touch sequences. (b) The plugin's accessibility describe returned
  frames without labels and zero elements at nav-bar coordinates on this
  sim — element-query navigation was unusable; screenshot + visual
  coordinates (points = pixels/3) was the workable path, consistent with
  DL74's "sequence automation on state, not pixels" caveat but inverted:
  here pixels were the only honest signal available.

### 2026-07-20 — M7b merged; M7 gate fully OPEN

- **Claude's in-depth review passed** (Spotlight observation seam, guard's
  structural never-strand, the DL87 fix's keying + cancellation, extension
  target shape) and Owen directed the merge sight-unseen on device — he's
  away from home. `feat/system-m7b` merged to `main` (`--no-ff`, 11b8281).
  **Every human VERIFY item that closes M7 is outstanding**: home-screen
  search finds a real item without opening the app · Siri answers "where
  are the Christmas lights" · Control Center button at the shed door ·
  Seasonal shows everything Seasonal · index survives a sync cycle · the
  seeding guard offers the join on a second device · plus DL87's deliberate
  scan-B-while-on-A check and the sim-blocked intent *run* (DL89). Run 11's
  Spotlight-categories question is pending Owen below.

### 2026-07-20 — M6.2 merged; gate PARTIALLY closed

- Claude's review passed (bootstrap convergence onto one join path, race
  guards, scope containment all verified) and **Owen's initial device pass
  passed — including the dispatch's headline live: a reinstall joined the
  real household with no invite.** `feat/ipad-m6-2` merged to `main`
  (`--no-ff`, ac603dc). **Still open to fully close M6.2** (Shelley's
  iPad): her edits attributing correctly on other devices · independent
  theme choice · real camera scan + label print from the iPad · Split View
  next to another app with live sync · the inverted beta rule (her iPad is
  the beta device). The run's Question for Owen (a discovery guard before
  "Set Up This Home Instead" seeds) is pending his ruling below.

### 2026-07-20 — M4c gate closed

- **Owen's on-device pass passed** — Family, Labels, Categories, and Sync
  Activity themed with no white flashes or readability issues; the label
  preview reads as a white sheet on the themed desk; Classic unchanged.
  `feat/themes-m4c` merged to `main` (`--no-ff`, 5322e00). Every screen
  except Onboarding is now themed, per the DL58 resolution. Board: **M7b
  or M6.2 next** (Owen's pick); M4's human gate (soak + Shelley's
  sign-off) continues unaffected. Light-mode severity-color contrast note
  (DL76) stands as feed for M6's a11y audit.

### 2026-07-20 — Run 10 (M6.2, iPad support — local Mac, green build)

Slice per `planning/m6.2-ipad-kickoff-prompt.md`, on `feat/ipad-m6-2` off
`main` at 998fedd. Scope held: `Sync/` touched **only** in the onboarding
bootstrap path the kickoff names (`ShareAcceptance.swift` + new
`SharedZoneBootstrap.swift`) — engine, mapper, schema, migrations untouched;
no `project.yml` change beyond the device-family/orientation keys; the DL20
write paths untouched. Built and tested under stable Xcode 26.6 —
`scripts/test.sh` green on **both device families**: 214 tests / 25 suites
on iPhone 17 (iOS 26.5) *and* on **iPad Pro 11-inch (M5)** (iOS 26.5 — the
logged iPad model, pinned to DL14's runtime). No script fork: the DL14
`SIM_NAME`/`SIM_OS` overrides already select the destination; both scripts
now document the iPad usage in their headers. Two new suites:
SharedZoneBootstrapTests (4) and AdaptiveLayoutTests (3).

- **DL78 — iPad enablement is configuration + size classes, not a rewrite.**
  `TARGETED_DEVICE_FAMILY "1,2"`; all four iPad orientations via the
  `~ipad` Info.plist key (iPhone stays portrait-only, so a Max-size phone
  can never hit the regular-width paths); `UIRequiresFullScreen`
  deliberately absent — Split View / Slide Over / windowed resizing is in
  scope and verified: resizing the app to an arbitrary iPadOS 26 window
  relays out live to the compact (iPhone) layout with the themed background
  filling every size (`artifacts/m6.2/27-window-resized-arcade.png`). The
  TabView adopts `.tabViewStyle(.sidebarAdaptable)` — iPad gets the native
  top-bar/sidebar treatment (both modes verified in-sim), iPhone keeps its
  bottom tab bar.
- **DL79 — `Design/AdaptiveLayout.swift` is the one new layout seam.** Pure,
  tested decisions: `contentMaxWidth(isRegularWidth:)` (672 pt readable cap;
  nil = compact no-op, the DL54 discipline applied to layout) and
  `roomGridColumnCount(forWidth:)` (2–4 columns targeting ~300 pt tiles).
  The `readableContentWidth()` modifier centers grouped List/Form content
  and fills the released side space with the screen's own background —
  `theme.bg` themed, `systemGroupedBackground` for Classic — so themed
  surfaces stay edge to edge at every width. Applied to Settings (+ both
  pickers), Family, Search, Container/Room detail, Scan's manual form, and
  Sync Activity. Judgment calls: Rooms home trades the list for a card grid
  of the T11 accent-cycle tiles **only in regular width** (compact keeps
  the exact iPhone list — a 50/50 split pane is compact and gets it);
  EditButton is compact-only, grid deletes ride each card's context menu
  into the same confirmation, and reorder stays a compact affordance.
  Editors present as true form sheets (`.presentationSizing(.form)`); the
  label-PDF preview gets `.presentationSizing(.page)` — the white page on
  the themed desk (DL75) finally has room. Onboarding caps at 480 pt; scan
  result cards cap at 520 pt (an 88 pt Fen stays an 88 pt Fen everywhere —
  the existing fixed frames already satisfied the cap rule).
- **DL80 — Popover audit (every dialog/share/print path, with outcomes).**
  (a) `UIPrintInteractionController.present(animated:)` was the one real
  iPad bug — iPhone-shaped API with no popover anchor. Fixed: an invisible
  `PrintAnchorView` rides behind the preview's Print button and
  `present(from:in:)` anchors there (identical behavior on iPhone);
  verified on iPad — the full print panel presents correctly. (b) Dialogs
  with a stable triggering control were re-anchored onto it and verified
  presenting as row-anchored popovers: Settings reset, Family leave,
  onboarding's owner-switch. (c) Screen-level dialogs with no stable anchor
  (RootView join, Rooms-home swipe/context delete, container-detail
  menu delete, item editor's two, theme picker's icon offer) present as
  sane centered popovers/alerts — verified for the container delete and
  the icon offer (which also re-proved DL59's present-after-select timing
  on the new idiom); the rest share the same presentation machinery.
  (d) `ShareLink` self-anchors at its toolbar button (verified);
  `UICloudSharingController` and the photo pickers present as sheets, no
  anchor needed. One cosmetic finding: the label sheet's bottom-bar
  "Generate Label Sheet" button renders icon-only on iPad (iPhone keeps
  the labeled button) — functional, noted for the M6 a11y audit.
- **DL81 — Second-device bootstrap: discovery joins what acceptance
  already granted.** CKShare acceptance is per-Apple-ID, so a fresh install
  on a participant account has the `Household` zone sitting in its shared
  database and no callback coming (the DL29 gap). New
  `SharedZoneBootstrap.outcome` (pure, tested: zone + virgin/pristine →
  adopt silently; zone + data-bearing → the DL33 replace dialog; no zone →
  the invite-waiting flow stands) and `SharedZoneDiscovery` (read-only
  `sharedCloudDatabase.allRecordZones()` + best-effort share fetch for the
  roster — inbound sync refreshes it anyway, DL32). `ShareAcceptanceModel`
  generalized to a `PendingJoin` of invite-vs-discovered — same phases,
  same RootView dialog/overlay/alert, same one-transaction `wipeAndAdopt`
  (untouched), no accept step on the discovered path. Discovery runs from
  the waiting screen on appear and on every foreground (DL26 discipline),
  with a pre-configure buffer mirroring the invite buffer — a cold launch
  into the waiting screen runs the child view's task before the root
  configures the model, and without the buffer it would silently dead-end.
  An explicit invite always outranks a discovered zone. **Owen's on-device
  §3 VERIFY effectively passed early**: Shelley's iPad (fresh install,
  committed build) → "Join a Household" → hydrated into the real household
  with no new invite.
- **DL82 — What run 1 of Owen's device pass actually was (incident note).**
  The first install came from this working tree *mid-edit* (the branch had
  no commit yet), a state where the waiting screen either lacked discovery
  or carried the cold-launch dead-end above; "Join" then waits forever and
  the escape hatch ("Set Up This Home Instead") seeds an owner household —
  after which DL29-by-design offers no path back to joining except
  reinstall. Consistency check that the real household was never touched:
  leaving it would have been CloudKit remove-self, after which the
  reinstall could not have discovered the zone — but it did, and joined.
  Mitigations shipped: the waiting screen now says second devices connect
  automatically with no invite; the branch is committed so device builds
  are defined states. The harder guard is a Question below.
- **DL83 — iPad-sim automation field notes (extends DL74/DL77).** On the
  fresh CC-M62-iPad sandbox (iPad Pro 11-inch M5, 26.5): (a) idb text
  input **works** — the DL74(b) all-channels-dead typing failure is an
  iPhone-sandbox affliction, not universal; tap-typing was never needed.
  (b) idb HID taps address the **portrait-native** coordinate space
  regardless of UI orientation — landscape taps silently land elsewhere
  (masquerading as DL77's swallowed-taps trap). Rule: interact in
  portrait; rotate (Simulator ⌘←/⌘→ via System Events) only to capture.
  (c) `simctl ui <udid> appearance dark` flips appearance live, no
  relaunch. (d) The iPadOS 26 window-resize handle drags fine with the
  DL77-approved `idb ui swipe` CLI — the fastest way to exercise
  arbitrary-width relayout.
- **DL84 — Evidence accounting (what the M6.2 captures actually measured).**
  (a) *iPhone regression ("zero deltas on compact"):* the M4a screen set
  (Rooms, room detail, container detail, item editor, Scan, Settings) was
  captured twice on the CC-M7a-Sandbox iPhone 17 sim — same DB, same
  navigation, status bar pinned 9:41 — once on a fresh `main` build (998fedd,
  built in a throwaway worktree) and once on this branch, compared as
  uncompressed BMP bytes. Four screens are **byte-identical** (0 differing
  pixels of 3.16 M); container detail differs by literally one pixel
  (channel delta 1); the item editor differs only in a full-width strip at
  the sheet's bottom edge — 0.30% of pixels, 83% at channel delta 1, max
  14 — the DL76 Liquid Glass material-sampling noise. Zero content deltas.
  (b) *iPad set* (`artifacts/m6.2/`): Rooms grid / container detail /
  editors / Scan manual + success card / Search / Settings + both pickers
  across Classic light, Pop! light (+ Pop! dark via the system setting),
  and Arcade dark; portrait and landscape; sidebar and top-bar tab modes;
  the DL80 popover audit shots; and the windowed arbitrary-width resize
  relayout. The DL7 label-slot write from the audit's PDF generate is the
  sandbox's own catalog (never the live iPhone 17 sim — DL27's rule held;
  all interactive work ran on the fresh CC-M62-iPad sandbox).

### 2026-07-20 — Run 11 (M7b, "The House That Knows" — local Mac, green build)

Slice per `planning/m7-polish-plan.md` §3 (M7b): U8–U10 + U13–U14 under
U11/U12, plus the Run 10 seeding-guard rider. Zero schema, zero sync
surface held by construction and by measurement: no migration, the DL20
write paths and `RecordMapper`/`SyncCoordinator` untouched, `Sync/` touched
only by the rider (new `SeedingGuard.swift`; `ShareAcceptance` grew an
`adopt(discovered:)` seam the rider reuses; `DiscoveredHouseholdZone`
became Equatable for the tests). One `project.yml` change: the U10 widget
extension target. Built and tested under stable Xcode 26.6 —
`scripts/test.sh` green on BOTH families: **248 tests / 29 suites** on
iPhone 17 and on iPad Pro 11-inch (M5), both iOS 26.5 (four new suites:
CategoryBrowseTests, SpotlightIndexTests, IntentResolutionTests,
SeedingGuardTests; DeepLinkTests +6). Sandbox-sim session on
CC-M7a-Sandbox (never the live iPhone 17 sim) ended byte-stable:
`pending_changes` 50 → 50 and `sync_events` 0 → 0 with **identical table
dump SHA-256s** across the whole interactive session — category browsing,
both search paths, three highlight deep links, Spotlight pull-down search
+ a cold-start result tap, and a Shortcuts-app visit moved nothing
(receipts in `artifacts/m7b/`; the 50 includes a documented pre-baseline
catalog fixture written to give browsing/search something to find).

- **DL85 — U13 shape.** The browse view's rows are *items* (room section
  headers, container as each row's subtitle — consecutive rows sharing it
  read as the room → container grouping), each row a NavigationLink to its
  container with that item as the U14 highlight. Grouping is a pure
  ordered pass (`CategoryBrowse.grouped`) over one query ordered
  room `sort_order` → container name → item name. CategoriesView rows
  became NavigationLinks; **editing moved to trailing swipe** (Edit +
  Delete replacing `onDelete` — same swipe-only delete semantics as
  before), and the Categories *sheet* navigates within its own stack
  (`catalogDestinations()` on the sheet's NavigationStack) rather than
  dismissing to the catalog. Search's category rows are real links to the
  same route. Header chips echo container detail: item count in the
  category's own color, room count in accent2.
- **DL86 — U14 mechanics.** `Route.container` gained `highlightItemID`
  (a `static func container(id:)` keeps plain call sites unchanged —
  enum cases can't default associated values); container URLs may carry
  `?item=<uuid>` (parsed case-insensitively, DL1-normalized, malformed
  ignored — printed labels never carry it, so the QR contract is
  untouched). The emphasis is the theme's accent at 25% as the matched
  row's `listRowBackground` — the Inside section's row surfaces resolve
  through one helper so the override can't fight `themedRow()` — with
  scroll-to-center after a 300 ms layout beat and a settle-away at
  ~2.1 s, all through `motion.animation(.settle, reduceMotion:)` (the
  plain fade under Reduce Motion — the existing DL60 seam, U12). The
  choreography state lives on the screen, not the row (DL62).
- **DL87 — Stack-replace kept the old destination alive (real bug, found
  live; latent on main).** With `navigationDestination(for: Route.self)`,
  a DL5 stack-replace that swaps the top route swaps the view VALUE but
  keeps its *structural identity* — plain `.task {}` observations and
  @State survive, so the screen kept showing the OLD container (verified:
  two successive item deep links; the second never re-observed). Latent on
  main for Camera-scan-while-viewing-a-container. Fix: the three catalog
  destination views key their observation tasks with `.task(id:
  <entityID>)` and reset their loaded state on change; the highlight task
  keys on the target id. The cleaner `.id(route)` on the destination
  **segfaults** the iOS 26.5 sim runtime (EXC_BAD_ACCESS in generic-
  metadata instantiation, reproducible — the DL62 family of runtime
  landmines), so identity is keyed at the task level instead.
- **DL88 — U8 seam: observation-driven, launch-rebuilt, diffed.** The
  chosen seam is one `ValueObservation` over a full searchable snapshot
  (`SpotlightCatalog.entries`) — both DL20 write paths end in a commit,
  and a commit is all the observation needs, so LocalMutation and
  ServerApply feed the index without either knowing it exists, and an
  index failure structurally *cannot* touch a catalog write. First
  emission after launch clears and rebuilds (convergence no matter what
  an earlier run left); after that a pure diff prunes deletions and
  re-indexes only changed entries — reset (DL33 wipe → empty snapshot)
  and join fall out of the same diff, and a participant degrade (catalog
  kept, DL34) correctly keeps its index. Writes are batched (200) and
  failure-tolerant: the diff baseline advances only on a fully-applied
  pass, so failed batches retry on the next change. Identifiers ARE the
  deep links (`cluttercatcher://c/<uuid>`, items adding `?item=` — U14),
  so a tapped result is just `router.open(url:)`, the tested DL5 path;
  containers and items are indexed per U8's letter (categories are
  findable through their items' keywords and browse in-app — flagged
  below). Thumbnails resolve from the photo cache at index time; a photo
  whose bytes arrive later stays a text-only result until the next
  change/launch touches its entry (accepted, self-healing). Item-name
  changes also re-donate the U9 App Shortcut parameters.
- **DL89 — U9 shape, and a sim signing limitation.** Entity resolution is
  a pure layer (`ItemIntentResolution`: exact → prefix → substring, each
  alphabetical, LIKE-escaped) the AppIntents types wrap thinly;
  `AppDatabase` reaches the queries via `AppDependencyManager`. Find
  Item's dialog is exactly the location phrase ("Holiday Bins in the
  Garage — 5 items"; possessive room names drop "the"), and both intents
  open the app through `OpenURLIntent` + the deep-link vocabulary — no
  new navigation plumbing, DL73 semantics test-pinned. Verified in-sim:
  both actions appear under ClutterCatcher in the Shortcuts composer, the
  Open Scanner App Shortcut tile renders. **Running** an App Shortcut on
  the simulator fails ("Unable to run App Shortcut"): linkd can't derive
  a team identity from a "Sign to Run Locally" build ("Unable to get
  teamId from com.rixun.cluttercatcher") — a sim-signing limitation, not
  app behavior; the run/Siri half rides Owen's device gate, where builds
  carry the real team.
- **DL90 — U10 XcodeGen shape.** `ClutterCatcherControls`: type
  `app-extension`, `NSExtensionPointIdentifier
  com.apple.widgetkit-extension`, embedded via a target dependency with
  `embed: true`, same team/signing family, `CFBundleShortVersionString`/
  `CFBundleVersion` mirroring the app's (embedded-extension validation
  requires the match). Content is one file: a `WidgetBundle` hosting a
  `ControlWidget` button whose intent (`openAppWhenRun` +
  `OpenURLIntent("cluttercatcher://scan")`) is defined in the extension —
  dependency-free by design (no GRDB, no app code; the URL literal is the
  frozen M7a contract). Builds and embeds clean on both families;
  pressing the control is on Owen's device VERIFY (Control Center).
- **DL91 — Seeding-guard choices.** Timeout: **4 seconds** (generous for
  a warm CloudKit round trip; an offline first owner barely notices).
  Timeout/offline/error collapse into one `unavailable` on purpose —
  only *proof* of a household interposes. The interposed dialog offers
  "Join My Household" (primary; hands the already-discovered zone to
  `ShareAcceptanceModel.adopt(discovered:)` — the M6.2 machinery, same
  decision table, phases, and one-transaction wipe-and-adopt) and an
  explicit destructive-styled "Start a Separate Catalog Anyway" — the
  guard warns, it never forbids, keeping the never-strand principle even
  against a false positive. Both onboarding screens share the dialog via
  one modifier; the escape hatch disables during the ≤4 s check. Live
  sim walkthrough covered the unavailable→proceed state (fresh sim, no
  iCloud: tap → brief check → seeded owner catalog); found/no-zone are
  seam-tested (SeedingGuardTests drive the race with injected
  discoveries, including a 30 s hang beaten by a 50 ms timeout). The
  found-zone dialog live is Owen's check, per the kickoff.
- **DL92 — Sandbox field notes (extends DL74/DL77/DL83).** (a) On this
  iPhone sandbox `idb ui swipe` silently no-ops WITHOUT `--duration`;
  with `--duration 0.3+` it's reliable — the DL77 rule refined. (b) Every
  text-injection channel is still dead there (DL74b reconfirmed);
  software-keyboard **tap-typing** (⌘⇧K to disconnect the hardware
  keyboard first) is the dependable path, and it works fine in the
  springboard's Spotlight field too. (c) No route into the springboard
  Home worked (idb HOME button, ⌘⇧H, Device-menu click) — `simctl
  terminate` is the honest way off the app, and it turned the Spotlight
  test into a cold-start deep-link proof. (d) Spotlight itself works on
  the sim: pull-down search indexed our items ("Wreath — Kitchen →
  Holiday Bins" under a ClutterCatcher header) and tapping it launched
  the app into the highlighted container. (e) The app's data-container
  path rotates on reinstall — re-resolve before poking the DB. (f) The
  browse/search fixture was written straight into the sandbox DB (items +
  matching `pending_changes` rows, timestamps in GRDB's format) *before*
  the receipts baseline — documented, so the byte-stable claim measures
  exactly the interactive session.

## 2026-07-19 — Planning: M7 "Polish & The House That Knows" (with Owen)

Born from the post-M4b polish review. New milestone, spec'd and
dispatch-ready:

- **Spec:** `planning/m7-polish-plan.md` (decisions **U1–U12**). Two
  dispatches: **M7a** in-app polish (scanner torch, item move-to-container,
  post-create label nudge, Rooms subtitle thresholds, household-English
  scan copy, empty-room rows, room icon picker, `cluttercatcher://scan`
  route) and **M7b** system integration (Core Spotlight, App Intents +
  Siri, Control Center scan control — all iOS 26-capable).
- **Kickoff:** `planning/m7a-kickoff-prompt.md` (M7b's follows its gate).
- **Renumbering:** old M7 "iOS 27 harvest" → **M8**; D3's API ceiling now
  reads "until M8"; App Intents + Spotlight pulled out of M6's scope into
  M7. M8's drag-items interaction is the gestural layer over U2's
  functional move — kept, not duplicated.
- **Zero schema anywhere in M7**: U2 (`container_id`) and U7 (`rooms.icon`,
  already seeded and live in Production) are ordinary tracked writes;
  Spotlight's index is derived, rebuildable local state fed from both
  write-path commit points without touching the DL20 types.
- **Sequencing:** no hard dependency on M5/M6 in either direction —
  dispatch order is Owen's call under the one-open-milestone rule;
  M7a → M7b is the only fixed ordering.

## 2026-07-20 — Planning: deep-review amendments + M6.2 iPad dispatch (with Owen)

A code-level walk of the feature surface (while M7a was being dispatched)
found real gaps; Owen ruled on placement:

- **U13 — Category browse (→ M7b).** Categories currently label but can't
  *find*: search's category results render without a NavigationLink
  (untappable) and CategoriesView taps open the editor, not the contents.
  New `Route.category(id:)` browse view (items grouped room → container);
  also U8's prerequisite — indexed categories need a destination.
- **U14 — Matched-item highlight (→ M7b).** Item search results land on
  the container without indicating the match; the container route gains an
  optional highlight id (scroll-to + brief emphasis). Spotlight/intents
  reuse it.
- **M6 scope additions:** destructive-delete confirmations name their
  blast radius with live counts; accessibility audit (VoiceOver on
  icon-only controls, Dynamic Type at the largest sizes, themed contrast —
  Arcade especially). M6 header now reads *partially shipped* (photos
  Run 4, HEIC/GC M6.1).
- **M8 preconditions made explicit:** Xcode 27 GM + all four family
  devices on iOS 27 + the D3 target bump (a one-way door for dev-signed
  installs). M8 is last by construction.
- **M6.2 iPad dispatch written:** `planning/m6.2-ipad-kickoff-prompt.md` —
  `TARGETED_DEVICE_FAMILY 1,2`, size-class-driven layout (sidebarAdaptable
  tabs, readable widths, popover-anchor audit, themed surfaces at
  arbitrary widths), and the one sync-adjacent item: the
  **participant-second-device bootstrap**. Shelley's iPad is a fresh
  install on an already-participant Apple ID — CKShare acceptance is
  per-account, so the shared `Household` zone already exists in her shared
  database, but DL29's join flow only knows the invite-callback path and
  would wait forever. Fix: on "Join a household", discover the existing
  shared zone and adopt via the DL33 wipe-and-adopt transaction, no invite
  needed. Bootstrap code only; zero schema, zero contract change.

## Questions for Owen

### Run 11 (M7b)

1. **Should categories be Spotlight-indexed too?** The M7 plan's summary
   line says "containers/items/categories" but U8's decision text names
   containers and items only — Run 11 shipped U8's letter (DL88). Interim
   answer (most reversible): **not indexed** — a category is still
   findable in system search through its items (the category name rides
   every item entry's keywords: searching "Seasonal" surfaces the Seasonal
   items), and the browse view is one tap in-app. Indexing categories
   directly would need a category deep-link URL form (`Route.category`
   is in-app-only today) — a small, self-contained addition if the
   family's muscle memory turns out to be "search the category name."

### Run 10 (M6.2)

1. ~~**Should "Set Up This Home (Instead)" check for a discoverable household
   first?**~~ **Resolved (Owen, 2026-07-20): yes — build the guard.** Run
   one discovery (with a timeout) before `becomeOwner`; when a `Household`
   zone exists in the account's shared database, interpose "This Apple ID
   is already in a household — join it instead?" and re-route into the
   join. On timeout/offline, the genuine-first-owner path proceeds as
   today (the guard must never strand a real owner without a network).
   **Rides the M7b kickoff as a one-item rider** rather than its own run.
   Owen's field report corroborates DL82: the first onboarding attempt on
   the second device was "weird" (the warming-iCloud window); the second
   attempt joined smoothly — the guard closes the one dangerous edge of
   that window, and the shipped waiting-screen copy + foreground re-runs
   already soften the rest.

### Run 6 (M4a)

1. ~~**Theme surface coverage beyond the touch-list (DL58).**~~ **Resolved
   (Owen, 2026-07-20): theme everything.** Family, Labels, Categories, and
   Sync Activity get full theming (`themedScreen()`/`themedRow()`);
   Onboarding alone stays system — it renders before anyone has picked a
   theme, so theming it is dead code. Dispatched as its own mini-run
   **M4c** (`planning/m4c-kickoff-prompt.md`), ahead of M7b/M6.2 — both of
   whose kickoffs already defer to this ruling. Does not disturb M4's human
   gate (soak continues; Shelley's sign-off still closes M4).

All four Run 4 questions resolved (Owen, 2026-07-19, post-VERIFY-start):

1. ~~**HEIC vs JPEG (P12).**~~ **Resolved: switch to HEIC** — shipped in Run 5
   (DL51). iPhone-only fleet on iOS 26+ — HEIC native since iOS 11,
   decode is content-based so existing JPEG cache files and already-uploaded
   JPEG assets coexist with new HEIC ones; no migration. Keep the JPEG-encode
   fallback path per the original P12 wording.
2. ~~**Auto-cover the first photo in a coverless container?**~~ **Resolved:
   deferred** — stays manual-only for now; moved to the parking lot as **FU2**,
   to revisit after polish.
3. ~~**Inbound/cascade stale-file cleanup (DL44).**~~ **Resolved: build the
   "clean up unused photos" GC sweep.** Scope-corrected during the decision:
   the leak is orphaned cache bytes only — it never affects correctness and
   never forces a reinstall; this is a disk-tidiness feature for a years-lived
   family app. Design constraint: the sweep must never delete refs staged in an
   open editor session (`sessionRefs` are DB-invisible until Save), so it runs
   on demand from Settings or at launch before any editor exists — never on a
   background timer. Shipped in Run 5 (DL52/DL53).
4. ~~**"Re-download Photos" reach (P13).**~~ **Resolved: ship as-is.**
   Best-effort re-fetch is the accepted behavior; a token-reset affordance is
   only warranted if the kept-token/lost-files case is ever actually hit
   on-device.

### Check-first for Owen (uncompiled — verify these before a clean build)

API signatures I could not confirm without the SDK, ranked by risk:
- `PhotosPicker` flow: `.photosPicker(isPresented:selection:matching:)` +
  `PhotosPickerItem.loadTransferable(type: Data.self)` (ItemEditorView).
- `CameraPicker`'s `UIImagePickerController` delegate under strict concurrency
  — mirrored the proven `DataScannerRepresentable` `@MainActor`-coordinator
  shape, but the picker's `.originalImage`/delegate specifics are unverified.
- `MagnificationGesture` (FullScreenPhotoView) — may be soft-deprecated in
  favour of `MagnifyGesture`; expect at most a warning.
- CKAsset attach/read (`record["photo"] = CKAsset(fileURL:)`,
  `record["photo"] as? CKAsset`) and `record["photo"] = nil` clear semantics.
- `UIImage` `Sendable`ness is deliberately NOT relied on — no `UIImage`
  crosses an isolation boundary (the loader offloads only `Data`).

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

## Environment note — Run 4 (M6 item photos)

Same situation as Run 1: executed in a Linux container with **no Xcode, no
Swift toolchain, no `xcodegen`, no simulator**. The branch
`claude/item-photos-m6-1eeil1` is **reviewed source, not a green build** — no
`xcodegen generate` / `scripts/build.sh` / `scripts/test.sh` was (or could be)
run here, and none is claimed. A deliberate self-review pass ran against the
Run 1.1 first-build traps (DL12–DL14) plus this slice's specifics
(strict-concurrency actor boundaries, `#expect`-can't-throw, ≤ iOS 26 API
surface), including independent multi-lens review of the diff; fixes from it
are folded in. Expect small first-build fixups concentrated in the "Check-first
for Owen" list above. **Owen's local gate** (`xcodegen generate` →
`scripts/build.sh` → `scripts/test.sh` → simulator screenshots → the on-device
two-account CKAsset/cover/wipe VERIFY) and the P14 Production schema deploy are
his steps, exactly as the M6 plan specifies.

*Update (merge, 2026-07-19): the local gate's build/test half PASSED on Owen's
Mac under stable Xcode 26.6 — `scripts/test.sh` green, 154 tests / 17 suites
including the four M6 suites (PhotoStore, PhotoAndCover, Migration,
RecordMapping), with **zero** first-build fixups; the "Check-first" list all
compiled clean. Still open: simulator screenshots (optional) and the on-device
two-account CKAsset/cover/wipe VERIFY + P14 Production deploy.*

## Future upgrades / parking lot

- **FU1 — Dedicated container photo (item-photos Variant B).** A photo *of the
  container itself* (the bin, or the open box showing its contents), stored on
  the `containers` record as its own CKAsset — distinct from the user-designated
  cover, which just points at an existing item's photo (see
  planning/m6-photos-plan.md P4/P10). Would add a second copy of the item-photo
  machinery aimed at `containers`: a `photo_asset_ref` column + `photo` CKAsset
  field on Container, mapper handling both ways, capture UI, and the P8/P9 asset
  side-effects on the container apply path. Deferred by Owen at the M6-photos
  design (2026-07-19); revisit if the designated-cover approach proves
  insufficient.
- **FU2 — Auto-designate the first photo in a coverless container as its
  cover** (user still overrides; m6-photos-plan §10). Deferred by Owen
  (2026-07-19): stays manual-only through polish; revisit after the polish
  milestone.

## 2026-07-19 — Planning: M4 rewritten as "Make It Yours" (with Owen)

Shelley designed a five-theme system + six app icons for ClutterCatcher in
her own Claude Design session (inspired by the Talaria work). Owen and
Claude (chat) restructured M4 around it; full sub-plan in
`planning/m4-themes-plan.md` (decisions **T1–T14**), kickoff in
`planning/m4a-kickoff-prompt.md`. Summary of the planning decisions:

- **Old M4 was overtaken by events** — Shelley has been a live participant
  since the M3 gate (DL50 verified cross-account CKAssets on her phone).
  Its still-live residue (offline conflict script, one-week soak, Shelley's
  sign-off, stable-device control rule) folds into the new M4's human gate.
- **All five themes ship** (plus Classic as the untouched default), split
  into two dispatches: M4a (ThemeKit, pickers, alternate icons, layout/copy
  refresh, Fen empty-state figure **with idle blink** — Owen's floor for
  dispatch one) and M4b (per-theme motion personality + Fen behaviors).
- **Sequencing:** M4 runs after M6.1 (HEIC + GC); **M5 (Andrew + Michael)
  stays its own gate after M4** — Arcade is the carrot for the kids
  ("if we bore kids, they'll never use it again").
- **D16 amended** (T14): Fen presence is a per-theme dial; Dusk returns as
  the optional Dusk Redux theme; Classic stays default.
- **Zero sync surface by construction** (T2): theme id is a plain local
  `settings` write, icon state belongs to the system; a test asserts no
  `pending_changes` from theming. No schema, no CloudKit deploy, no
  Console step anywhere in M4.
- **Assets:** Claude (chat) extracted the token sheets (light + dark, all
  five themes) and rendered the six 1024pt app icons directly from the SVG
  definitions in Shelley's docs; committed under `design/icons/` with the
  reference canvases in `design/reference/` and Fen's shape geometry in
  `design/fen-geometry.md` (eyes are separate shapes so the blink is one
  animation). The `design/` folder arrives as a bundle Owen drops in at
  the repo root before dispatching M4a.
- DL numbering: M4 runs log DL entries starting after M6.1's allocations
  (DL51+ remains reserved for M6.1 per the Run 4 resolutions).
