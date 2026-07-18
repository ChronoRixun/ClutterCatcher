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

## Questions for Owen

1. **Seed room list.** Interim (reversible — rooms are editable/deletable
   in-app; fixed UUIDs mean answers can also ship as a data tweak before M2):
   Kitchen, Living Room, Office, Primary Bedroom, Andrew's Room,
   Michael's Room, Garage, Basement. Missing anything you'd label day one —
   Laundry, Attic, Hall Closet, Shed? Kids' rooms named right?
2. **Seed category list.** Interim: 11 categories (Seasonal & Holiday, Tools &
   Hardware, Electronics & Cables, Camping & Outdoor, Sports & Recreation,
   Toys & Games, Clothing & Textiles, Books & Media, Documents & Paperwork,
   Crafts & Hobbies, Keepsakes & Memorabilia). Trim/extend?
3. **Label sheet stock.** Two presets ship: Avery 5163-style 4″×2″ (default)
   and 5160-style 2⅝″×1″. Margins approximate the Avery templates — print one
   sacrificial sheet and eyeball alignment before a real batch (see device
   steps). Which stock are you actually buying?
4. **iPhone-only for now** (`TARGETED_DEVICE_FAMILY = 1`). iPad would mostly
   work via SwiftUI but is untested and unplanned until at least M6. OK?
5. **Slot semantics** (see DL7): slots record *print order*, they don't pin a
   container to a fixed cell position on every future sheet. If you want
   "reprint onto a partially-used sheet" (skipping used cells), say so and
   the layout already supports it — it's a UI affordance away.

## Watch-outs for M2/M3 (from Run 1 review)

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
