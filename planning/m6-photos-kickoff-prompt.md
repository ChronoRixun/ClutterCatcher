# Claude Code kickoff — M6 Item Photos

You are implementing the **Item Photos** slice of M6 for ClutterCatcher (CCv4),
locally in this repo. Branch `feat/item-photos` off `main`.

Read first, in order:
1. `planning/ccv4-plan.md` — locked decisions D1–D17, milestones (photos are the
   M6 "item photos (CKAsset)" line).
2. `OPEN_ITEMS.md` — decision log DL1–DL38, conventions.
3. `planning/m6-photos-plan.md` — **authoritative for this run**: decisions
   P1–P13, data model, sync design, touch-list (§9), tests (§7), VERIFY (§8).

Ground rules:
- XcodeGen is source of truth (D5). Run `xcodegen generate` after adding
  `PhotoStore.swift`; never hand-edit the `.xcodeproj`.
- Swift 6 strict concurrency; iOS 26 API surface only (D3).
- Keep the two write paths separate (DL20): local edits via
  `performLocalMutation`, inbound via `applyServerChanges`. The CKAsset copy
  (P8/P9) is the ONLY new inbound side-effect — row application stays verbatim.
- `cover_item_id` is a soft reference, no FK (P10). `photo_asset_ref` semantics
  are P6 — do not treat it as a file path.
- Do NOT claim CloudKit/CKAsset sync verification you can't perform. Simulators
  can't push (DL26); CKAsset upload/download and every two-device step are
  Owen's on-device VERIFY. Never stub sync to fake a pass.
- The Production schema deploy (§4) is Owen's step — do not attempt it; leave
  clear notes for it.
- Log implementation decisions to `OPEN_ITEMS.md` (D17). Anything the plan
  doesn't answer → "Questions for Owen" with the most-reversible interim answer;
  don't guess silently.

Deliver: implement the §9 touch-list per P1–P13, add the §7 tests, then output
the §8 VERIFY checklist with agent-verifiable evidence (build log, test results,
simulator screenshots) and the human/on-device items listed for Owen. Stop at
the gate.
