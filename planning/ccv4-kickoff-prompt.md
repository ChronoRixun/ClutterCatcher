# Claude Code Kickoff — ClutterCatcher v4, Run 1 (M0 + M1)

Paste everything below the line into Claude Code (or use as `/goal`), from the directory where the repo should live.

---

## Mission

Build **ClutterCatcher v4** milestones **M0 and M1 in this single run**: a complete, polished, fully working *local* iOS app — scaffold, data layer, all CRUD screens, QR label generation/printing, QR scanning with deep-link routing, seed data, and tests. **No CloudKit code beyond entitlements/scaffold.** Sync (M2+) is explicitly out of scope for this run and gated behind human verification.

The authoritative spec is `planning/ccv4-plan.md` (copy it into the repo first — it ships alongside this prompt). Read it fully before writing any code. Where this prompt and the plan disagree, the plan wins.

## Context you must respect

- App: QR-code home organization for a family of four. Rooms → Containers → Items, Categories orthogonal. Printed QR labels on physical bins resolve to container contents.
- Clean start: no legacy data, no legacy labels, no CCv3 code. Do not port React Native patterns; write idiomatic SwiftUI.
- This is a hobbyist labor of love. Craftsmanship over speed. Small, well-named types. No dead code, no speculative abstraction.

## Hard requirements

1. **Toolchain:** Xcode 27 beta is the daily driver but **deployment target is iOS 26.0 and the API surface must stay ≤ iOS 26**. If you reach for an API, confirm its availability; anything iOS 27-only is forbidden in this run. Build scripts must honor `DEVELOPER_DIR`.
2. **Project:** XcodeGen `project.yml` is the source of truth. Never hand-edit the `.xcodeproj`; regenerate after adding/removing files. Targets: `ClutterCatcher` (app), `ClutterCatcherTests`.
3. **Language:** Swift 6.x, strict concurrency enabled and clean (no `@unchecked Sendable` escape hatches without a justifying comment).
4. **Data:** GRDB via SPM. Schema per plan §3.1, including the local-only `settings`, `sync_state`, `record_metadata`, and `pending_changes` tables (created now, used in M2). UUID string primary keys. `ValueObservation` drives the UI.
5. **Seed (plan D12):** canonical rooms/categories with **fixed compiled-in UUIDs**, applied once behind a first-launch flag, idempotent, owner-only by design (participants concept arrives in M3 — for now the flag simply guards re-seeding).
6. **QR:** payload `cluttercatcher://c/<uuid>`; register the URL scheme; CoreImage generation (correction level Q); paginated Avery-style label-sheet PDF via `UIGraphicsPDFRenderer` + print/share; VisionKit `DataScannerViewController` scanner accepting both the URL form and bare UUIDs; unknown UUID → friendly not-found state.
7. **Entitlements/scaffold only for CloudKit:** iCloud/CloudKit capability with container `iCloud.com.rixun.cluttercatcher`, remote-notification background mode, `CKSharingSupported` in Info.plist, bundle ID `com.rixun.cluttercatcher`, team `DNL25ZFSD2`. **Do not write any CKSyncEngine/CKShare code.** Do not touch the CloudKit Console.
8. **Design:** apply tokens from `design/tokens.*` if present; otherwise create `Design/Tokens.swift` with tasteful Liquid Glass-era placeholders (system materials, one warm accent, Dynamic Type throughout) clearly marked for replacement. Standard chrome, color in content, per Apple's current brand guidance.
9. **Tests:** Swift Testing (XCTest interop allowed) covering: schema migrations, repository CRUD + cascades, seed idempotency, QR payload round-trip, deep-link routing. UI smoke via `xcrun simctl` scripted walkthrough is acceptable in place of full UI tests.
10. **Conventions:** `OPEN_ITEMS.md` decision log updated as you go; conventional commits; feature-folder layout per plan §3.5.

## Working method

- Start with a written implementation plan (plan mode): file tree, schema DDL, screen inventory, test list. Present it, then proceed — do not wait for approval unless a genuine blocker exists.
- **"Questions for Owen":** when you hit a real product decision the plan doesn't answer, add it under a `## Questions for Owen` section in `OPEN_ITEMS.md`, choose the most reversible option, mark it clearly, and continue. Never silently guess on irreversible choices.
- Verify constantly: `xcodegen generate` → build → test after every meaningful unit of work. A broken build is never left standing between commits.
- **Never fake verification.** If something can only be proven on a physical device (camera scanning, real printing), implement it properly, verify what the simulator can (deep links via `xcrun simctl openurl booted "cluttercatcher://c/<seed-uuid>"`, PDF artifact inspection), and list the device-only steps for Owen.

## Definition of done for this run

Output a final **VERIFY report** containing:

- [ ] `xcodegen generate` clean; `scripts/build.sh` and `scripts/test.sh` pass from a fresh clone
- [ ] Full test suite green (list counts)
- [ ] Simulator screenshot walkthrough: Rooms home, Room detail, Container detail, Item edit, Categories, Search, Scan screen, Label sheet preview, Family placeholder, Settings
- [ ] Deep link `cluttercatcher://c/<uuid>` navigates to the correct container in simulator (evidence)
- [ ] Generated label-sheet PDF attached/pathed for inspection
- [ ] `OPEN_ITEMS.md` current, including any Questions for Owen
- [ ] Explicit list of **device-only verification steps for Owen** (print a test sheet, scan with system Camera app, confirm routing)

Then **stop**. M2 (sync) begins only after Owen's on-device gate passes.
