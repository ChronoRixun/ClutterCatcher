# Claude Code kickoff — M4b: Motion & Fen personality

You are implementing dispatch **M4b** of the M4 milestone for ClutterCatcher
(CCv4), locally in this repo. Branch `feat/motion-m4b` off `main`.
**Precondition: M4a (`feat/themes-m4a`) is merged to `main` after Owen's
on-device pass** — if `main` doesn't contain ThemeKit
(`Design/Theme.swift`, `Design/ThemeStore.swift`, `Shared/FenFigure.swift`),
stop and say so.

Read first, in order:

1. `planning/ccv4-plan.md` — locked decisions D1–D17 (D16 as amended),
   milestones.
2. `OPEN_ITEMS.md` — decision log + conventions. **Especially DL54–DL59**
   (M4a's shipped shape: Classic's structural no-op, the `_APPICON_ASSETS`
   spelling, Fen's Pop! colors, the scan-card semantics, the touch-list
   coverage interim, the two presentation-timing lessons). Log your own
   entries as **DL60+**.
3. `planning/m4-themes-plan.md` — authoritative: §5 (Fen, M4b column),
   **§6 (motion personality table — your core spec)**, §7 M4b scope +
   VERIFY.
4. `design/fen-geometry.md` — shape coordinates incl. the **wink** and
   **pixel** variants.
5. `design/reference/` — Shelley's mockups for the feel of the reward
   moments (reference, not HTML to port).

Ground rules (unchanged from M4a):

- XcodeGen is source of truth (D5): `xcodegen generate` after file changes;
  never hand-edit the `.xcodeproj`.
- Swift 6 strict concurrency; iOS 26 API surface only (D3).
- **Zero sync surface (T2).** Motion is pure code — no schema, no
  migration, no settings writes, no CloudKit anything, `Sync/` untouched.
  M4a's zero-`pending_changes` theming test must stay green.
- Build/test with `scripts/build.sh` / `scripts/test.sh` (stable Xcode
  26.x per DL14's pinned simulator runtime). All existing suites stay
  green.
- Stop at the gate: commit on the branch, report VERIFY evidence, **do not
  merge**. M4's human gate (conflict script, week soak, Shelley's
  sign-off) belongs to Owen and Shelley, not this run.

## Scope

### 1. Motion token set — `Design/Motion.swift` (T10)

A per-theme `MotionPersonality` value hung off `Theme`, mirroring how
palettes work: values, not configuration. It carries at minimum the
theme's spring presets (the §6 table: Classic/Dusk system defaults, Cozy
slow-honey high-damping, Pop! bouncy overshoot with the scan pop at
`response .35, damping .6`, Fresh quiet-damped, Arcade snappy) and its
reward-moment style.

**Reduce Motion is a first-class dimension, not an afterthought.** Every
overshoot, stagger, confetti, glow, count-up, and Fen animation degrades
to a plain fade; the blink already pauses (FenFigure honors it — keep
that). Design the seam so Reduce Motion is *injectable* for tests
(environment-driven in views, parameter-driven in the token resolution),
with `@Environment(\.accessibilityReduceMotion)` as the production
source. A test must flip the flag and observe the implementation switch —
that's the §7 requirement.

### 2. Reward moments (§6 table)

On the scan-success "Found it!" card (DL57 — the card, its "Open It Up"
and quiet "Scan Again" buttons, and the manual-path top-slot placement
are shipped; you're adding personality, not changing semantics):

- **Pop!** — card entrance with the bouncy overshoot; a **one-shot
  confetti-dot burst** (once per card presentation, guarded — re-scans
  re-fire only with a fresh card) using the theme's accent trio; **Fen
  peeks over the card edge** (medium presence). Draw confetti with
  `Canvas`/`TimelineView`, modest particle count; it's a wink, not a
  fireworks show ("sherbet, not candy aisle").
- **Arcade** — glow pulse on the card (accent-colored shadow/stroke
  breathing once or twice, then settling) and a **score-tick count-up**
  on the item count (`contentTransition(.numericText())` or equivalent
  ≤ iOS 26 API).
- **Fresh** — a leaf unfurls: one small SwiftUI-shape leaf drawing itself
  in beside the container name. No confetti.
- **Cozy** — soft settle, no burst.
- **Classic / Dusk Redux** — standard transition.

Save reward: Pop!'s "drop-in" squash-settle on the saved row/sheet
dismissal; everyone else per table. **Haptics ship for all themes** (T10):
success notification on scan-found, soft impact on save.

### 3. Fen behaviors (§5, M4b column)

- **Ear-perk** on primary-button press where Fen is on screen (the
  empty-state "Add Your First Room" pattern) — Cozy and Pop!.
- **The wink** (geometry doc has the variant) — use it as a
  post-reward flourish on the Pop! scan-card peek; other placements are
  your judgment, logged.
- **Arcade pixel sprite** — the pixel variant from `fen-geometry.md`,
  replacing the smooth figure in Arcade's empty states and appearing in
  Scan per §5's presence row. Keep it shape-drawn (T9), no image assets.
- Placement/behavior judgment calls beyond the plan's words: pick the
  most reversible reading, log as DL, flag anything product-shaped as a
  Question for Owen.

### 4. Cross-cutting polish (§6)

- Staggered ~30 ms spring-settle on Rooms first load (first appearance
  per launch, not every navigation).
- Icon-picker tile bounce on selection (mind DL59's presentation-timing
  lessons — animate after state settles, verify in-sim).

### 5. Theme surface coverage — **check OPEN_ITEMS first**

The Run 6 "Questions for Owen" entry (DL58) asks whether full theming
extends to Family, Labels, Categories, and Sync Activity. **If Owen has
answered it in OPEN_ITEMS by the time you run, honor the answer** (the
extension is `themedScreen()`/`themedRow()`, two lines per screen). If it
is still open, ship touch-list coverage unchanged and leave the question
in place.

## Tests (§7)

- Motion tokens resolve per theme (all six, both the animated and
  Reduce-Motion variants).
- Reduce Motion flag switches implementations (the injectable seam).
- Confetti one-shot guard logic (pure-logic test if the view state is
  extractable; otherwise document why not).
- Everything existing stays green — expect ~178+ tests.

## VERIFY (agent — your evidence at the gate)

- `xcodegen generate` → build → `scripts/test.sh` green.
- Sim capture of the scan-success moment in **Pop!** and **Arcade**
  (frame sequence or GIF; a still of the settled card is not sufficient
  evidence of the animation).
- Sim spot-check: same flows with Reduce Motion enabled — fades only.
- Zero `pending_changes` / `sync_events` from any of this (M4a's test
  plus a manual sim check).

## VERIFY (human — Owen + Shelley; closes M4, not yours to run)

1. Motion personality distinct across Pop!/Cozy/Arcade on device; Reduce
   Motion honored.
2. Conflict script: both edit the same item offline → LWW resolves,
   receipts in both phones' Sync Activity (DL28).
3. One-week parallel-use soak on themed builds (DL19 stable-device rule).
4. Shelley signs off. M4 closes; M5 (Andrew + Michael, Arcade in hand)
   opens.

## Non-goals

No sounds (T10 — deferred until someone misses one). No new screens, no
navigation changes, no token/palette changes beyond adding motion. No
data-model, sync, or CloudKit surface of any kind. No iPad (M6). Nothing
from M5.
