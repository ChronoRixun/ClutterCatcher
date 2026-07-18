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

## Watch-outs for M2/M3 (from Run 1 review)

- **DatabasePool at M2 start:** switch `AppDatabase.onDisk()` from
  `DatabaseQueue` to `DatabasePool` (WAL) at the *start* of M2, before
  CKSyncEngine writes coexist with UI observation reads.
- **Participant seeding (D12):** `Seeder.seedIfNeeded()` currently runs
  unconditionally on first launch — correct while Owen is the only user. M3's
  share-acceptance path must set the seed flag *before* the first launch
  bootstraps from the shared zone, or a participant device would locally
  seed rooms/categories and later push them into the household zone,
  resurrecting anything Owen had renamed/deleted.
- **`updated_at` discipline:** every repository write method stamps
  `updatedAt` by hand today. M2's sync layer should centralize stamping (its
  outbound hook touches every write anyway) — a forgotten stamp would
  silently corrupt last-write-wins ordering (D10).
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
