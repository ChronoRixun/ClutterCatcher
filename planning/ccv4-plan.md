# ClutterCatcher v4 (CCv4) — Native Rebuild Plan

Date: 2026-07-17 · Status: **locked for kickoff** · Supersedes: cloudkit-sync-plan.md (CCv3/Expo line, retired)

---

## 1. Context

ClutterCatcher is a QR-code home organization app for one household of four (Owen, Shelley, Andrew, Michael — each on their own Apple ID). Printed QR labels on bins, drawers, and shelves resolve to what's inside. CCv3 (Expo/React Native) is retired; CCv4 is a **clean-start native SwiftUI rebuild**. No data or printed labels carry over. The rebuild journey is the point — quality over speed.

## 2. Locked decisions

| # | Decision |
|---|----------|
| D1 | Clean start. No migration from CCv3. No legacy printed labels to honor. |
| D2 | Native SwiftUI. Swift 6.x, strict concurrency. No React Native, no Expo. |
| D3 | **Deployment target iOS 26.0.** API surface stays ≤ iOS 26 until M7. |
| D4 | Daily dev toolchain: Xcode 27 beta (Owen's phone is on iOS 27 db3). Stable Xcode 26 stays installed for sanity-check builds and any future TestFlight upload. `DEVELOPER_DIR` selects toolchain for CLI builds. |
| D5 | Project generated from `project.yml` via **XcodeGen** (source of truth; regenerate when files are added/removed). |
| D6 | Local store: **SQLite via GRDB** (SPM). Live UI updates via GRDB `ValueObservation`. |
| D7 | Sync: **CKSyncEngine** (not NSPersistentCloudKitContainer, not SwiftData — SwiftData still has no sharing API as of WWDC26). |
| D8 | Sharing model: **one custom zone (`Household`) in Owen's private database, shared zone-wide via a single CKShare.** Owen owns the zone permanently. Participants (Shelley, Andrew, Michael) access it through their shared database. Default permission: read-write. |
| D9 | Row identity: **UUID primary keys, doubling as CKRecord recordNames and QR payloads.** No separate ckRecordName column. |
| D10 | Conflict policy: **last-write-wins** at record level (server ack ordering). Label slot collisions: LWW + pull-before-print. |
| D11 | `created_by`: derived automatically from CKRecord `creatorUserRecordID`; display names resolved via the CKShare participant roster. No manual people picker. |
| D12 | Seeding: **owner-only.** Owen's first launch seeds canonical rooms/categories with fixed UUIDs compiled into the app. Participants never seed — they bootstrap entirely from the shared zone. (This eliminates the CCv3 duplicate-seed problem by construction.) |
| D13 | Bundle ID `com.rixun.cluttercatcher`, team `DNL25ZFSD2`, container `iCloud.com.rixun.cluttercatcher` (reused; Development environment gets reset at M2 start). |
| D14 | Distribution: **development-signed direct installs** via cable/Wi-Fi for M0–M6 (paid team → 1-year profiles). TestFlight optional after Xcode 27 GM (~fall). |
| D15 | CloudKit environment strategy: Development env through M2 (schema churn allowed). **Before M4: deploy schema to Production and pin `com.apple.developer.icloud-container-environment = Production`** in dev-signed builds. All four devices always on the same environment. Real family data accumulates only in Production. |
| D16 | Design: fresh Liquid Glass-native identity from Claude Design exploration (see §6). Dusk system is not carried over. Fen permitted as empty-state cameo only. |
| D17 | Repo conventions mirror Talaria: `planning/`, `OPEN_ITEMS.md` decision log, `design/` reference folder, "Questions for Owen" convention, Swift Testing + XCTest interop. |

## 3. Architecture

### 3.1 Data model (SQLite, GRDB)

Hierarchy: **Rooms → Containers → Items**, with **Categories** orthogonal on Items.

Synced tables (all with `id TEXT PRIMARY KEY` = UUIDv4 string, `created_at`, `updated_at`, `created_by` nullable):

- `rooms` — name, sort_order, icon
- `categories` — name, color_token
- `containers` — room_id FK, name, notes, label_slot (nullable int)
- `items` — container_id FK, name, quantity, notes, category_id FK nullable, photo asset ref (nullable, M6)

Local-only tables:

- `settings` — key/value
- `sync_state` — serialized CKSyncEngine state, per-database change tokens
- `record_metadata` — per row: archived CKRecord system fields (encodedSystemFields blob), needed for correct saves/conflicts
- `pending_changes` — outbound queue (record id, type, change kind)

Deletes are hard deletes locally + CKRecord deletion; FK cascade Room→Containers→Items mirrored as explicit cascading CK deletes queued in dependency order.

### 3.2 Sync engine

- Two `CKSyncEngine` instances: **private DB engine** (owner role — Owen) and **shared DB engine** (participant role — everyone else). Role determined at runtime by whether the local user owns the `Household` zone.
- Record type per table; recordName = row UUID; zone = `Household`.
- Outbound: DB write → row into `pending_changes` → engine `nextRecordZoneChangeBatch` drains queue → on server ack, persist returned system fields into `record_metadata`.
- Inbound: engine delegate applies fetched changes directly to SQLite in a single transaction; GRDB observation refreshes UI automatically.
- Conflicts: on `serverRecordChanged`, re-apply local field values onto the server record (LWW by latest local edit) or accept server if local row untouched since last ack.
- Account changes / iCloud sign-out: engine paused, UI banner, data stays local.
- Push: silent CloudKit notifications (remote-notification background mode) trigger engine fetches; engine also schedules its own syncs.

### 3.3 Sharing (M3)

- Owner creates zone-wide `CKShare(recordZoneID:)` on `Household`; invite via `UICloudSharingController` wrapped for SwiftUI.
- Acceptance: `CKSharingSupported = true` in Info.plist; `UIApplicationDelegateAdaptor` + scene delegate implementing `windowScene(_:userDidAcceptCloudKitShareWith:)` → `CKAcceptSharesOperation` → start shared-DB engine.
- Participant roster read from the CKShare → maps opaque user record IDs → display names for `created_by` rendering.
- If the owner ever stops sharing, participants keep a read-only local snapshot (banner explains state).

### 3.4 QR labels

- Payload: `cluttercatcher://c/<uuid>` (containers; `r/` rooms reserved). Custom scheme registered so the system Camera app deep-links; in-app scanner (VisionKit `DataScannerViewController`, iOS 16+) also accepts bare UUIDs.
- Generation: CoreImage `CIQRCodeGenerator`, error correction Q.
- Printing: paginated label-sheet PDF (Avery-style grid, configurable) via `UIGraphicsPDFRenderer` → `UIPrintInteractionController` / share sheet. `label_slot` assignment pulls latest sync state before allocating (D10).
- Scan → resolve UUID → navigate to Container detail; unknown UUID → friendly "not in your catalog" state.

### 3.5 App structure

Targets: `ClutterCatcher` (app), `ClutterCatcherTests` (Swift Testing + XCTest interop). Feature-folder layout: `App/`, `Data/` (GRDB, models, repositories), `Sync/` (engines, mapping, share), `Features/` (Rooms, Containers, Items, Scan, Labels, Family, Search, Settings), `Design/` (tokens, components), `Shared/`.

## 4. Milestones

Gate rule unchanged from CCv3 discipline: **a milestone's VERIFY checklist must fully pass before the next begins.** Each milestone ends with Claude Code outputting the checklist with evidence (build logs, test results, screenshots).

### M0 — Scaffold *(agent-verifiable)*
Repo init; `project.yml` (targets, iOS 26 deployment, Swift 6 strict concurrency, entitlements: iCloud/CloudKit container, remote notifications background mode, `CKSharingSupported`); SPM: GRDB; scripts (`scripts/build.sh`, `scripts/test.sh` honoring `DEVELOPER_DIR`); `OPEN_ITEMS.md`; placeholder design tokens.
**VERIFY:** `xcodegen generate` clean · `xcodebuild build` (sim) clean · empty test suite runs · app boots to placeholder screen in simulator (screenshot).

### M1 — Complete local app *(agent-verifiable — the "stars" run, combined with M0)*
GRDB schema + migrations; repositories; owner seed (D12) behind first-launch flag; full CRUD UI for Rooms/Containers/Items/Categories; local search; QR generate + label PDF + print sheet; VisionKit scanner + URL-scheme deep link routing; design tokens applied from chosen Claude Design direction; unit tests for data layer, seed idempotency, QR payload round-trip, deep-link routing.
**VERIFY:** all tests pass · simulator screenshot walkthrough of every screen · scan-to-navigate proven in sim (inject URL via `xcrun simctl openurl`) · label PDF artifact rendered and eyeballed · **on-device pass on Owen's iPhone** (human): scan a physically printed label with the system Camera → lands on the right container.

### M2 — Private-zone sync *(agent-implementable, human-verified)*
Reset CloudKit **Development** env schema in Console (human, one click). Private DB CKSyncEngine; `Household` zone; record mapping; pending-changes pipeline; system-fields persistence; LWW conflict handler; account-status handling; push registration.
**VERIFY (human, single Apple ID):** edit on iPhone → appears in simulator (signed into same Apple ID) and vice versa · offline edits reconcile on reconnect · forced conflict resolves LWW · CloudKit Console shows expected record types/records · kill-and-relaunch resumes cleanly from serialized engine state.

### M3 — Zone sharing *(agent-implementable, human-verified)*
Deploy schema to **Production**; pin environment entitlement (D15). Zone-wide CKShare creation; sharing controller; scene-delegate acceptance path; shared-DB engine; role detection; participant roster → `created_by` names; stop-sharing/read-only fallback.
**VERIFY (human, two Apple IDs — Owen + a spare/secondary):** invite link sends · acceptance opens app and hydrates full catalog · bidirectional edits within ~seconds · `created_by` shows correct names both sides.

### M4 — Shelley *(human gate)*
Install on Shelley's iPhone (iOS 26 stable — this is also the beta-OS control device check). Real invite, real acceptance, one week of genuine parallel use. Conflict script: both edit the same item offline → LWW confirmed, nothing lost silently.
**VERIFY:** Shelley signs off. Any CKShare weirdness seen on Owen's iOS 27 db3 phone is cross-checked against Shelley's stable device before debugging code (beta-seed CKShare regressions are a known hazard).

### M5 — Andrew + Michael *(human gate)*
Two more invites; 4-participant roster; per-device install ritual documented in `docs/family-setup.md`; label printing session — first real physical labels go up in the house.
**VERIFY:** all four devices converge on the same catalog; each member's edits attributed correctly.

### M6 — Hardening + polish *(mixed)*
Sync status UI; error surfaces; empty states (Fen cameo); JSON export/backup; item photos (CKAsset) if desired; App Intents + Core Spotlight indexing of items (**iOS 26-capable** — "where are the Christmas lights" from system search); iPad support (`TARGETED_DEVICE_FAMILY = 1,2` + layout pass; target device: Shelley's iPad, iPadOS 27 beta — runs an iOS 26-target app fine); optional TestFlight migration post-GM (data already in Production per D15, so it's seamless).
**VERIFY:** export/reimport round-trip; Spotlight finds a known item; family still syncing after 2 weeks.

### M7 — iOS 27 harvest *(parking lot, after family updates in fall)*
Reorderable List containers (drag items between containers); App Intents `SyncableEntity` + Siri semantic search; Foundation Models with image prompts + Vision barcode/OCR tools → "photograph the open bin, get a suggested item list."

## 5. Claude Code run strategy

- **Run 1 (now, ambitious): M0+M1 in one goal.** Fully machine-verifiable; no CloudKit code beyond entitlements/scaffold. Kickoff prompt: `ccv4-kickoff-prompt.md`.
- **Runs 2+: one milestone per run**, each starting by reading this plan + `OPEN_ITEMS.md`, each ending with the VERIFY checklist and a stop for Owen's gate.
- Claude Code must never simulate, stub, or claim sync verification it cannot perform; multi-account steps are explicitly Owen's.

## 6. Design track (parallel, before M1 UI work)

Explore in Claude Design (standalone session, not the CCv3 repo): 3 directions → Owen picks → full screen set + token sheet → exports and tokens committed to `design/` in the new repo. Claude Code translates tokens into `Design/Tokens.swift`; mockups are reference, not literal HTML to port.

## 7. Risks & sharp edges

- **CKShare on beta seeds** — historically the flakiest subsystem (iOS 26 cycle: beta acceptance breakage; 26.4 sync regression fixed in 26.4.1). Mitigation: M4's stable-device control check; keep family devices updated.
- **Dev vs Production environment mismatch** — silently empty shares. Mitigation: D15; environment asserted at startup in debug builds.
- **SwiftUI + scene-delegate share acceptance** — easy to wire wrong; covered by explicit M3 verify step.
- **Annual dev-profile expiry** — calendar reminder; TestFlight (M6) removes it.
- **Zone-wide share participant ceiling (~100)** — irrelevant at 4, noted for completeness.

## 8. Open items at kickoff

1. Repo location on the Mac (suggest `~/dev/cluttercatcher`) — Owen confirms in kickoff.
2. Chosen design direction — feeds M1's token file; M1 can start with placeholder tokens if design isn't picked yet.
