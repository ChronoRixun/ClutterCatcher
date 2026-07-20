# Claude Code kickoff — M7a: In-app polish

You are implementing dispatch **M7a** of the M7 milestone for
ClutterCatcher (CCv4), locally in this repo. Branch `feat/polish-m7a` off
`main`.

**Precondition check, in order:** M4 may or may not be fully closed
(its human gate runs on wall-clock time — conflict script, week soak,
sign-off) and M5/M6 may not have run; none of that blocks M7a. What DOES
block you: if `main` lacks ThemeKit (`Design/Theme.swift`) or
MotionPersonality (`Design/Motion.swift`), you're on the wrong base —
stop and say so.

Read first, in order:

1. `planning/ccv4-plan.md` — locked decisions D1–D17, milestones (note
   M7/M8 renumbering).
2. `OPEN_ITEMS.md` — decision log + conventions. Log your entries as DL
   numbers continuing from the current maximum **at run time** (other
   runs may have landed since this kickoff was written). Check whether
   the DL58 theming-coverage question has been answered; honor it either
   way (U12).
3. `planning/m7-polish-plan.md` — **authoritative for this run**:
   decisions U1–U12, M7a scope + VERIFY (§3). M7b items (Spotlight,
   App Intents, Control Center) are OUT of scope — except the
   `cluttercatcher://scan` route, which is explicitly M7a's (U10
   prerequisite).

Ground rules (unchanged):

- XcodeGen is source of truth (D5): `xcodegen generate` after file
  changes; never hand-edit the `.xcodeproj`.
- Swift 6 strict concurrency; iOS 26 API surface only (D3, ceiling now
  named M8).
- **Zero schema, zero CloudKit surface (U11).** U2 (item move) and U7
  (room icon) are ordinary tracked writes through *existing* synced
  fields via the LocalMutation path — nothing else touches sync at all.
  `Sync/` untouched. No migration. No Console step.
- Every new UI resolves through ThemeKit + MotionPersonality with Reduce
  Motion honored (U12). Skeleton changes (U4–U6 copy/layout) ship for
  all themes including Classic, per the T8 precedent.
- Build/test with `scripts/build.sh` / `scripts/test.sh` (stable Xcode,
  DL14's pinned simulator). All existing suites stay green.
- Stop at the gate: commit on the branch, report VERIFY evidence with
  screenshots, do not merge. Use a fresh sandbox simulator for
  interactive verification — never the live-syncing iPhone 17 sim
  (the DL27/M4a precedent).

## Scope (plan §2–§3, condensed — the plan wins on any conflict)

1. **U1 — Torch toggle** on the live scanner. Shown only when
   `hasTorch`; themed; torch off whenever the scanner stops (DL11).
   `DataScannerViewController` doesn't expose torch — use the
   device-lock `torchMode` technique and verify coexistence; log the
   outcome as a DL. If it genuinely can't coexist, ship no torch and
   log the finding for Owen (a broken flashlight is worse than none).
   Note the simulator has no torch — structure the code so the button's
   visibility logic is testable and the torch call is isolated; actual
   torch behavior rides Owen's device VERIFY.
2. **U2 — "Container" row in the item editor** → picker grouped by
   room, current container checked. Staged, committed on Save via
   LocalMutation like every other field. Test asserts the expected
   `pending_changes` row and `updated_at` stamp.
3. **U3 — Label nudge** after creating (not editing) a container:
   inline "Print a label for this bin?" → label-sheet flow with the
   container preselected. Once per creation, dismissible, no persisted
   state. Mind DL59's presentation-timing lessons.
4. **U4 — Rooms subtitle threshold**: aspirational line while the
   catalog has no containers, counts line after. Pure function,
   unit-tested; threshold judgment logged.
5. **U5 — Manual-entry placeholder**: "Type the code from the label".
   Parsing unchanged.
6. **U6 — Empty-room row treatment**: lightest option that works in all
   twelve palettes; logged.
7. **U7 — Room icon picker** in the room editor: curated ~24 SF Symbols
   grid (household-appropriate; pick and log the set), current icon
   ringed, `Tokens.defaultRoomIcon` fallback. Tracked write;
   accent-cycle tint preserved on tiles.
8. **`cluttercatcher://scan` route**: local-only URL route that selects
   the Scan tab, exactly as a tap would. Covered by a parsing test.
   (The Control Center button that uses it is M7b.)

## Tests (plan §3)

Subtitle threshold; U2 move commit semantics; U3 one-shot logic; U7
persistence round-trip + nil fallback; scan-route parsing; all existing
suites green (~185+).

## VERIFY (agent — your evidence at the gate)

- `xcodegen generate` → build → `scripts/test.sh` green.
- Sandbox-sim screenshots: container picker, icon grid, label nudge,
  sparse-vs-populated Rooms subtitle, manual-entry copy — Classic light
  plus at least one themed pair.
- Zero `pending_changes` from all interactions except a deliberate
  U2/U7 edit (which must produce exactly its expected rows).

## VERIFY (Owen, on device — closes M7a)

Torch in the garage · move an item and watch it land correctly
attributed on Shelley's phone · create → nudge → print flow · themed
room icons · the copy reads right in daily use.

## Non-goals

Everything in M7b (Spotlight, intents, Control Center — except the scan
route above). No schema. No drag-and-drop moves (M8). No new Fen
surfaces. Nothing from M5/M6.
