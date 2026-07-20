# M7 — Polish & The House That Knows (UX polish + system integration)

Date: 2026-07-19 · Status: **locked for implementation** · Two dispatches
(M7a in-app polish, M7b system integration). Renumbers the old M7 ("iOS 27
harvest") to **M8**; pulls App Intents + Core Spotlight out of M6's scope
into this milestone. D3's API ceiling ("≤ iOS 26 until M7") now reads M8 —
everything here is iOS 26-capable.

## 1. Context & sequencing

Born from the post-M4b polish review (Owen + Claude chat, 2026-07-19): a
pass over the shipped screens and real-world workflow surfaced a set of
UX gaps (dark-garage scanning, item moves, developer-facing copy) and one
big opportunity — the app fulfilling its own Search-tab promise ("where
are the Christmas lights?") from the *system* search surface, without the
app being opened first.

Sequencing: **no dependency on M5 or M6 in either direction.** M7 is
listed after M6 in the plan, but M7a touches nothing M5/M6 need and can be
dispatched whenever Owen wants a polish run between gates — the standing
one-open-milestone discipline is the only constraint. M7b builds on M7a's
scan deep-link route, so M7a → M7b is the one hard ordering.

Overlap note: old-M7's "drag items between containers" (now M8) is the
*gestural* version of U2's functional move — U2 ships the capability on
iOS 26; M8 may later add the drag interaction on top. Not duplication.

## 2. Decisions (U-series)

- **U1 — Torch toggle in the scanner.** Bins live in garages, sheds, and
  closets — the darkest rooms in the house. A flashlight button overlays
  the live scanner, shown only when the device has a torch
  (`AVCaptureDevice.hasTorch`), themed like the rest of Scan, state reset
  when the scanner stops (DL11's session discipline). Implementation
  risk, flagged honestly: `DataScannerViewController` owns its capture
  session and doesn't expose torch control — the standard technique is
  locking the default video device and setting `torchMode` alongside it.
  The agent verifies coexistence on-sim/on-device reasoning and logs the
  outcome as a DL; if the scanner genuinely fights it, the fallback is a
  torch toggle on the *manual-entry* screen being dropped entirely
  (a broken flashlight is worse than none) with the finding logged for
  Owen.
- **U2 — Move an item to another container.** Reorganizing is the app's
  core loop; today it's delete-and-recreate. The item editor gains a
  "Container" row opening a picker grouped by room (current container
  checked). Staged like every other editor field, committed on Save via
  the LocalMutation path — an ordinary tracked write; LWW and receipts
  apply as with any edit. `container_id` already syncs; zero schema.
- **U3 — Post-create label nudge.** After creating a *new* container
  (never on edit), an inline offer: "Print a label for this bin?" →
  routes to the label-sheet flow with that container preselected. One
  offer per creation, dismissible, no persistent state, no nagging.
  Mirrors T7's icon-offer pattern: offer, never auto-act.
- **U4 — Rooms subtitle grows up with the catalog.** The "N rooms · N
  containers · everything has a home" line undersells itself over a
  young catalog full of "0 containers" rows. Sparse state (no containers
  yet) shows the aspirational line ("let's give everything a home");
  once containers exist, the confident counts line. Exact threshold is
  agent judgment, logged as a DL; the logic is a pure function,
  unit-tested.
- **U5 — Manual-entry copy in household English.** The scan fallback's
  placeholder drops `cluttercatcher://c/… or UUID` for "Type the code
  from the label". Input stays monospaced; parsing (full URL or bare
  UUID, case-normalized per DL1) is unchanged.
- **U6 — Empty-room rows stop reading as dead weight.** The lightest
  treatment that works across all twelve palettes: dim the "0
  containers" secondary line and/or a subtle "Add a bin" affordance on
  empty rooms. Agent picks the lightest consistent option, logged.
  Like T8's refresh, U4–U6 are *skeleton* changes — they ship for all
  themes, Classic included.
- **U7 — Room icon picker.** `rooms.icon` already exists, syncs, and is
  live in Production (seed rooms carry icons — the field predates DL50's
  audit). The room editor gains an icon grid: a curated set of ~24
  household-appropriate SF Symbols (rooms, storage, vehicles, hobbies),
  current icon ringed, `Tokens.defaultRoomIcon` as the nil fallback.
  Ordinary tracked write; the icon tile keeps its T11 accent-cycle tint.
- **U8 — Core Spotlight indexing (M7b).** Containers and items become
  `CSSearchableItem`s: name, room path ("Garage → Holiday Bins"),
  category, thumbnail from the photo cache where one exists. The index
  is **derived local state, rebuildable** — updated from both write
  paths' commit points (LocalMutation and ServerApply) without touching
  the sync contract or the DL20 types themselves (the seam is the
  agent's choice, logged; observation-driven is acceptable). Deletions
  prune; catalog reset, household join (DL33 wipe), and participant
  degrade (DL34) trigger a full reindex or clear. Tapping a result deep
  links through the existing UUID routes — DL5's stack-replacing
  navigation, same as a QR scan.
- **U9 — App Intents (M7b).** A "Find Item" intent resolving an item by
  name and answering with its location phrase ("Holiday Bins in the
  Garage — 5 items") plus opening the container; an "Open Scanner"
  intent; both registered as App Shortcuts with natural Siri phrases
  ("Where are the Christmas lights in ClutterCatcher"). Read-only
  against the database; no writes from intents in this milestone.
- **U10 — Control Center + Lock Screen scan control (M7b).** A
  `ControlWidget` button that launches straight into the scanner — the
  shed-door use case. Requires a `cluttercatcher://scan` URL route
  (new, local-only, added in **M7a** so M7b builds on it); the route
  selects the Scan tab exactly as a tap would.
- **U11 — Zero sync surface, stated precisely.** No schema change
  anywhere in M7. U2 and U7 are ordinary tracked writes through
  existing synced fields; everything else (torch, copy, nudge,
  Spotlight index, intents, control) is local. No CloudKit Console
  step exists in this milestone. The M4a zero-`pending_changes`
  theming test stays green, and M7b adds the equivalent assertion for
  index/intent operations.
- **U12 — Theming and motion consistency.** Every new surface resolves
  through ThemeKit (`themedScreen()`/`themedRow()` per the DL58
  outcome, whichever way Owen rules) and MotionPersonality; Reduce
  Motion honored via the existing seam. Fen does not appear on any new
  surface (presence dial unchanged).

## 3. Dispatches

### M7a — In-app polish *(agent-implementable, Owen-verified)*

Scope: U1–U7 + the `cluttercatcher://scan` route (U10's prerequisite),
under U11/U12.

Tests: subtitle threshold logic (U4, pure function); move-item commit
produces exactly the expected `pending_changes` row and stamps
`updated_at` (U2); nudge one-shot logic (U3); room icon persistence
round-trip + nil fallback (U7); scan-route parsing; existing suites
green.

**VERIFY (agent):** `xcodegen generate` → build → tests green ·
sim screenshots: item editor with the container picker, room editor icon
grid, the label nudge, empty-vs-populated Rooms subtitle, manual-entry
copy — Classic light + one themed pair minimum · zero
`pending_changes` from everything except a deliberate U2/U7 edit.
**VERIFY (Owen, on device):** torch toggle in the actual garage (the
real test) · move an item between containers and watch it land on
Shelley's phone with correct attribution · create a container → nudge →
print flow · pick a room icon, see it themed on the tile · subtitle and
copy read right in daily use.

### M7b — The house that knows *(agent-implementable, family gate)*

Scope: U8–U10, under U11/U12. Precondition: M7a merged.

Tests: searchable-item payload building (name/path/category, thumbnail
ref resolution); prune-on-delete and clear-on-reset/join logic at the
seam; intent entity resolution (exact, partial, no-match); zero
`pending_changes`/`sync_events` from indexing and intents.

**VERIFY (agent):** build/tests green · sim: Spotlight result for a
seeded item deep-links to the right container; intent resolves in the
Shortcuts app.
**VERIFY (human — closes M7):** a household member finds a real item
from the home-screen search **without opening the app first** · Siri
answers "where are the Christmas lights" with the location · the
Control Center button opens the scanner at the shed door · index
survives a sync cycle (edit on one phone, search finds the new name on
the other).

## 4. Non-goals

No schema or CloudKit change of any kind. No drag-and-drop item moves
(M8's gestural layer). No write-capable intents. No widgets beyond the
scan control. No iPad (M6). No sounds. No new themes or Fen behaviors.
