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
| D3 | **Deployment target iOS 26.0.** API surface stays ≤ iOS 26 until M8. |
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
| D16 | Design: fresh Liquid Glass-native identity from Claude Design exploration (see §6). Dusk system is not carried over. Fen permitted as empty-state cameo only. *Amended 2026-07-19 (T14, `planning/m4-themes-plan.md`):* Shelley's five-theme system supersedes the single-identity assumption — Fen presence is a per-theme dial (none → full pixel sprite), and Dusk returns as an optional theme (Dusk Redux). Classic (today's look) remains the default. |
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

### M4 — Make It Yours: themes + personalization *(rewritten 2026-07-19 · runs after M6.1)*
Supersedes the original "Shelley" gate, whose install/invite half was overtaken by events (Shelley has been a live participant since the M3 gate; cross-account CKAsset verified on her device, DL50). Full sub-plan: **`planning/m4-themes-plan.md`** (decisions T1–T14). Shelley's five-theme system (Claude Design; `design/reference/`) ships as two dispatches: **M4a** ThemeKit + six themes light/dark + Make It Yours (theme picker, six alternate app icons) + lead-screen layout/copy refresh + Fen empty-state figure with idle blink; **M4b** per-theme motion personality + Fen behaviors. Theme/icon are per-device local settings — zero sync surface.
**VERIFY (closes M4, folds in old-M4 residue):** the offline conflict script (both edit the same item → LWW, receipts in both Sync Activity logs) · one-week parallel-use soak on themed builds · beta weirdness cross-checked on Shelley's stable device first · Shelley signs off.

### M5 — Andrew + Michael *(human gate)*
Two more invites; 4-participant roster; per-device install ritual documented in `docs/family-setup.md`; label printing session — first real physical labels go up in the house.
**VERIFY:** all four devices converge on the same catalog; each member's edits attributed correctly.

### M6 — Hardening *(mixed · partially shipped: item photos Run 4 + HEIC/GC M6.1)*
Remaining scope: sync status UI; error surfaces; JSON export/backup; destructive-delete confirmations name their blast radius with live counts ("Deletes 4 containers and 32 items from everyone's catalog"); accessibility audit (VoiceOver labels on icon-only controls, Dynamic Type at the largest sizes, contrast check on themed palettes — Arcade especially); **iPad support** (`TARGETED_DEVICE_FAMILY = 1,2` + layout pass — size-class-driven adaptation, not a stretched phone layout; includes the participant-second-device bootstrap so Shelley's iPad joins without a new invite; dispatch: `planning/m6.2-ipad-kickoff-prompt.md`; target device: Shelley's iPad, iPadOS 27 beta — runs an iOS 26-target app fine); optional TestFlight migration post-GM (data already in Production per D15, so it's seamless).
**VERIFY:** export/reimport round-trip; family still syncing after 2 weeks.

### M7 — Polish & The House That Knows *(mixed · added 2026-07-19)*
Full sub-plan: **`planning/m7-polish-plan.md`** (decisions U1–U14). Two dispatches: **M7a** in-app UX polish (scanner torch toggle, move-item-between-containers, post-create label nudge, Rooms subtitle thresholds, household-English scan copy, empty-room row treatment, room icon picker, `cluttercatcher://scan` route) and **M7b** system integration + findability (**iOS 26-capable**: category browse — categories finally *find* things — matched-item highlight, Core Spotlight indexing of containers/items/categories, App Intents + Siri — "where are the Christmas lights" answered from the home screen — and a Control Center scan control). Zero schema; U2/U7 are ordinary tracked writes; everything else is local. No hard dependency on M5/M6 — dispatch order is Owen's call under the one-open-milestone rule; M7a → M7b is the only fixed ordering.
**VERIFY (closes M7):** a household member finds a real item from system search without opening the app first; Siri answers a "where is" question; the Control Center button opens the scanner; the index survives a sync cycle.

### M8 — iOS 27 harvest *(parking lot · LAST, hard preconditions; was M7)*
**Cannot start before all of:** Xcode 27 GM shipped · all four family devices updated to iOS 27 (fall) · D3's deployment-target bump to iOS 27 (a one-way door for the household — dev-signed installs from the new target won't run on any straggler device).
Reorderable List containers (drag items between containers — the gestural layer over M7's functional move); App Intents `SyncableEntity` + Siri semantic search; Foundation Models with image prompts + Vision barcode/OCR tools → "photograph the open bin, get a suggested item list."

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
