# Claude Code kickoff — M7b: The House That Knows

You are implementing dispatch **M7b** of the M7 milestone for
ClutterCatcher (CCv4), locally in this repo. Branch `feat/system-m7b` off
`main`. Precondition: M7a is merged (`Design/Motion.swift`,
`Shared/DeepLink.swift`, and the item editor's container picker must
exist on `main`) — if not, stop and say so. M6.2 (iPad) and M4c (full
theming) are also on `main`: every screen you build is born themed AND
iPad-aware.

Read first, in order:

1. `planning/ccv4-plan.md` — locked decisions D1–D17, milestones.
2. `OPEN_ITEMS.md` — conventions; DL numbering continues from the current
   maximum at run time. Required context: **DL58's resolution** (theme
   everything — your new screens included), **Run 10's resolved question**
   (the seeding-guard rider below — that entry is its authority), DL67–74
   (M7a's shipped shape: the ScanView-hoisted state, the DeepLink
   pattern), DL78–84 (M6.2: AdaptiveLayout, popover-anchor discipline,
   the discovery machinery you'll reuse).
3. `planning/m7-polish-plan.md` — **authoritative**: §2 decisions
   U8–U14, §3 M7b scope/tests/VERIFY, §4 non-goals.
4. `design/fen-geometry.md` — only if an empty state needs Fen; the
   presence dial does NOT extend to new surfaces (U12).

Ground rules (unchanged): XcodeGen source of truth (D5) — this run DOES
touch `project.yml` (the control widget needs an extension target; see
scope); Swift 6 strict concurrency, iOS 26 API ceiling (D3); build/test
via `scripts/build.sh` / `scripts/test.sh`, green on BOTH device
families (M6.2's SIM_NAME override); stop at the gate, don't merge;
sandbox sims only, never the live-syncing iPhone 17 sim; **zero schema,
zero sync-contract surface (U11)** — the Spotlight index is derived,
rebuildable local state; indexing, intents, browsing, and the control
must leave `pending_changes`/`sync_events` untouched, test-asserted.

## Scope, in build order (plan §3)

### 1. U13 — Category browse

`Route.category(id:)`: the category's items grouped room → container,
each row navigating to its container via U14's highlight route.
CategoriesView row tap goes here (editing moves to a toolbar/swipe
affordance — judgment, logged); search's category results become real
NavigationLinks. Themed (`themedScreen()`/`themedRow()`), iPad-aware
(`readableContentWidth()`), empty-category state handled.

### 2. U14 — Matched-item highlight

The container route gains an optional highlight-item id: navigation
scrolls to and briefly emphasizes the matched row — theme-settle
animation through MotionPersonality, plain appearance under Reduce
Motion. Search item results use it immediately; Spotlight and the Find
intent reuse the same route. Mind the M7a lesson (DL62): container rows
get recreated — anchor the scroll/emphasis state above the row.

### 3. U8 — Core Spotlight indexing

Containers and items as `CSSearchableItem`s: name, room path ("Garage →
Holiday Bins"), category, thumbnail from the photo cache where one
exists. Fed from BOTH write paths' commit points (LocalMutation and
ServerApply) **without touching the DL20 types or the sync contract** —
the seam is your choice, logged (observation-driven is acceptable).
Deletions prune. Catalog reset, household join (DL33 wipe), and
participant degrade (DL34) clear or rebuild the index — hook the same
transitions the photo cache uses. Tapping a result deep-links through
the existing UUID routes (DL5 stack-replace), with the highlight id for
items. Index writes are batched and failure-tolerant: a CoreSpotlight
error must never fail a catalog write.

### 4. U9 — App Intents

"Find Item" (resolve by name; answer with the location phrase —
"Holiday Bins in the Garage — 5 items" — and open the container,
highlighted) and "Open Scanner" (the M7a `cluttercatcher://scan` route's
logic, as an intent). Both as App Shortcuts with natural Siri phrases.
Read-only against the database; no writes from intents.

### 5. U10 — Control Center scan control

A minimal WidgetKit extension target hosting a `ControlWidget` button
that launches the scanner (OpenURLIntent → `cluttercatcher://scan`, or
the equivalent ≤ iOS 26 pattern). **This is the run's one `project.yml`
change**: a new extension target, embedded in the app, same team/signing
family — keep the extension dependency-free (no GRDB import; it's a
button). Log the XcodeGen shape as a DL.

### 6. RIDER — the seeding guard (Run 10 resolved question; its entry in
OPEN_ITEMS is authoritative)

"Set Up This Home (Instead)" runs one `SharedZoneDiscovery` check (with
a timeout — pick a short one and log it) before `becomeOwner`. Zone
found → interpose "This Apple ID is already in a household — join it
instead?" re-routing into the existing join path (the discovered-zone
machinery from M6.2 already does the rest). Timeout, offline, or
discovery error → proceed as today: **the guard must never strand a
genuine first owner without a network.** Applies to both the onboarding
choice and the waiting screen's escape hatch. Seam-test the decision
logic (found/not-found/timeout) without CloudKit.

## Tests (plan §3 + rider)

Category-browse grouping query (ordering, empty category);
highlight-route parsing; searchable-item payload building (name/path/
category, thumbnail ref resolution); prune-on-delete and
clear-on-reset/join at the seam; intent entity resolution (exact,
partial, no-match); seeding-guard decision logic; zero
`pending_changes`/`sync_events` from browsing, indexing, intents, and
the guard; existing suites green on both families (~214+).

## VERIFY (agent — your evidence at the gate)

- `xcodegen generate` → build both families (app + extension) → tests
  green on both.
- Sandbox-sim evidence: a category row and a category search result
  both open the browse view; an item search result lands scrolled-to
  with the match emphasized (frames, not a settled still); a Spotlight
  result for a seeded item deep-links to the right container
  (`simctl` + the Search pull-down works on sim); the intents resolve
  in the Shortcuts app; the seeding-guard dialog appears when a zone is
  discoverable (sim walkthrough of the decision states is acceptable
  where CloudKit isn't reachable — the live check is Owen's).
- iPad spot-check of the browse view (readable width, popover-anchored
  affordances) in one themed palette.
- Queue receipts: `pending_changes`/`sync_events` byte-stable across
  the whole interactive session.

## VERIFY (human — closes M7)

A household member finds a real item from the home-screen search
**without opening the app first** · Siri answers "where are the
Christmas lights" with the location · the Control Center button opens
the scanner at the shed door · tapping Seasonal shows everything
Seasonal, across rooms · the index survives a sync cycle (edit on one
phone, search finds the new name on the other) · the seeding guard:
"Set Up This Home Instead" on a second device now offers the join
instead of seeding.

## Non-goals

No write-capable intents. No widgets beyond the scan control. No drag
moves (M8). No new Fen surfaces, no motion changes beyond U14's
emphasis. No schema, no Console step, nothing in `Sync/` beyond the
rider's guard call. Nothing from M5 or the rest of M6.
