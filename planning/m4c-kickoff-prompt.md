# Claude Code kickoff — M4c: themed-surface completion

You are implementing mini-dispatch **M4c** for ClutterCatcher (CCv4),
locally in this repo. Branch `feat/themes-m4c` off `main`. This is a
small, focused run: extend full theming to the screens the M4a interim
left system, per Owen's DL58 resolution. It does not disturb M4's human
gate (the soak continues regardless; Shelley's sign-off still closes M4).

Read first, in order:

1. `OPEN_ITEMS.md` — conventions; **DL54 and DL58** (the shipped ThemeKit
   shape and the interim this run replaces), and the resolved DL58
   question under "Questions for Owen" (this run's authority). Log your
   entries as DL numbers continuing from the current maximum at run time.
2. `planning/m4-themes-plan.md` — §3 token sheet, §4 refresh, **T5**
   (Liquid Glass substrate: system bars, sheet *chrome*, and materials
   keep native treatment — themed content backgrounds inside sheets are
   fine and are exactly what this run adds).

Ground rules (unchanged): XcodeGen source of truth (D5) — though this
run likely needs no `project.yml` change; Swift 6 strict concurrency,
iOS 26 API only (D3); zero schema, zero sync surface — nothing here
writes anything; `scripts/build.sh` / `scripts/test.sh` green; stop at
the gate, commit on the branch, don't merge; sandbox sim only, never the
live-syncing iPhone 17 sim.

## Scope — the ruling

**Themed** (apply `themedScreen()` + `themedRow()`, exactly the M4a
pattern — Classic short-circuits to its structural no-op for free):

- `Features/Family/FamilyView.swift`
- `Features/Labels/LabelSheetView.swift`
- `Features/Categories/CategoriesView.swift`
- `Features/Settings/SyncActivityView.swift`

**Explicitly untouched:**

- **Onboarding** — renders before anyone has picked a theme; stays
  system forever per the ruling.
- **`CloudSharingView`** — wraps `UICloudSharingController`, a system
  UIKit surface; stays native.
- **Editor sheets** (`CategoryEditorView` etc.) — already consistent
  with the M4a editors; only touch them if they visibly clash next to
  their newly themed parents (judgment, logged).

## Watch-fors (log outcomes as DLs)

- **The label PDF preview must stay white.** Labels print on white
  sticker stock; the *screen* around the preview is themed, the
  rendered sheet content is not. Verify the preview surface reads as
  "a white page on a themed desk" in all twelve palettes — especially
  Arcade dark.
- **Sync Activity severity colors** and **category color dots** were
  designed against system backgrounds — check contrast on all twelve
  palettes; destructive/warning stay system semantic colors (T3).
- CategoriesView is sheet-presented from Rooms home: themed content
  background inside native sheet chrome (T5) — mind DL59-family
  presentation timing if anything animates on appear.
- These four screens now themed means the app has NO system-background
  screens left except Onboarding — do a quick navigation sweep in a
  themed palette to catch any flash-of-system-background transitions
  between them.

## Tests

Existing suites stay green (~207). The M4a zero-`pending_changes`
theming test already covers this run's guarantee; add assertions only if
something logic-bearing emerges (none expected — this is view-layer).

## VERIFY (agent — your evidence at the gate)

- `xcodegen generate` → build → `scripts/test.sh` green.
- Sandbox-sim screenshots of all four screens in **Pop! light, Pop!
  dark, Arcade dark, Cozy light**, plus **Classic light side-by-sides
  vs `main`** (zero deltas — the no-op contract).
- The label-sheet preview shot in Arcade dark specifically (white page,
  themed desk).
- Zero `pending_changes` / `sync_events` from the whole session.

## VERIFY (Owen, on device — closes M4c)

Flip through Family, Labels, Categories, and Sync Activity in your theme
and in Arcade — no white flashes, no unreadable text · print preview
still reads as a white sheet · Classic user (if anyone) sees nothing
changed.

## Non-goals

No M7b content (category *browse* is U13, not this run — CategoriesView
keeps its current tap behavior here). No motion changes, no new Fen
surfaces, no Onboarding theming, no iPad work (M6.2).
