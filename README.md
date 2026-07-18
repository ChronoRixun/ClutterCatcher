# ClutterCatcher

A whole home storage solution: QR labels on bins, drawers, and shelves that
resolve to what's inside. Native SwiftUI, one household, built with care.

## Status

**M0 + M1 complete (pending Owen's on-device gate)** — full local app: rooms →
containers → items with orthogonal categories, live search, QR label
generation and Avery-style label-sheet printing, VisionKit scanning, and
`cluttercatcher://c/<uuid>` deep links. No sync yet; that's M2+. The
authoritative plan lives in `planning/ccv4-plan.md`.

## Toolchain

- Xcode 27 beta daily driver, **deployment target iOS 26.0** (API ≤ iOS 26).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `project.yml` is the
  source of truth. Never edit the `.xcodeproj` — it's gitignored; regenerate.
- Swift 6 language mode, strict concurrency. GRDB 7 via SPM.

## Building

```sh
brew install xcodegen                     # once
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer  # optional (D4)
scripts/build.sh                          # xcodegen generate + simulator build
scripts/test.sh                           # full test suite
scripts/ui-smoke.sh                       # boot sim, install, screenshot; set CONTAINER_UUID to test deep links
```

`SIM_NAME` overrides the default simulator (`iPhone 17`).

## Layout

```
planning/          plan + per-run implementation plans
ClutterCatcher/    app sources — App/ Data/ Features/ Design/ Shared/
ClutterCatcherTests/
scripts/           build / test / ui-smoke
OPEN_ITEMS.md      decision log + Questions for Owen
```
