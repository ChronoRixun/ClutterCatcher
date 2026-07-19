# Claude Code kickoff — M4a: ThemeKit + Make It Yours

You are implementing dispatch **M4a** of the rewritten M4 milestone for
ClutterCatcher (CCv4), locally in this repo. Branch `feat/themes-m4a` off
`main`. **Precondition: M6.1 (HEIC + GC) is merged** — if it isn't, stop
and say so.

Read first, in order:
1. `planning/ccv4-plan.md` — locked decisions D1–D17 (note D16 as amended),
   milestones.
2. `OPEN_ITEMS.md` — decision log + conventions.
3. `planning/m4-themes-plan.md` — **authoritative for this run**: decisions
   T1–T14, token sheet (§3), layout refresh (§4), Fen (§5), M4a scope +
   VERIFY (§7), touch-list (§8). M4b items (motion personality, ear-perk,
   peeks, pixel sprite, confetti) are OUT of scope — do not start them.
4. `design/fen-geometry.md` — Fen shape coordinates and per-theme colors.
5. `design/reference/` — Shelley's mockups (open the `.dc.html` files in a
   browser if useful). Mockups are reference, not HTML to port.

Ground rules:
- XcodeGen is source of truth (D5). After adding files and the
  `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_NAMES` setting, run
  `xcodegen generate`; never hand-edit the `.xcodeproj`.
- Swift 6 strict concurrency; iOS 26 API surface only (D3).
- **Zero sync surface (T2).** Theme state is a plain local `settings`
  write — never `performLocalMutation`, never a `pending_changes` row.
  The required test asserts this. Touch nothing in `Sync/`.
- Classic must stay pixel-equivalent to today's app apart from rounded
  type and the §4 layout refresh — it is the regression baseline.
- Icon PNGs are pre-rendered in `design/icons/` — copy into appiconsets;
  do not regenerate or re-render them. If `design/icons/` is missing,
  stop and tell Owen to drop in the design bundle first.
- Respect the two write paths (DL20) everywhere the §4 refresh touches
  editors — the refresh restyles views; repository calls are unchanged.
- The blink (T9/§5) ships in this dispatch: `FenFigure` idle blink on
  empty states for Cozy/Pop!/Arcade. Keep the timer paused off-screen.
- Log implementation decisions to `OPEN_ITEMS.md` (D17); DL numbers start
  after M6.1's allocations. Anything the plan doesn't answer →
  "Questions for Owen" with the most-reversible interim answer.

Deliver: implement §7 M4a scope per the touch-list, add the §7 tests,
then output the M4a VERIFY checklist with agent-verifiable evidence
(build log, test results, simulator screenshots incl. the Classic
side-by-side) and the on-device items listed for Owen and Shelley. Stop
at the gate; M4b gets its own kickoff after Owen's pass.
