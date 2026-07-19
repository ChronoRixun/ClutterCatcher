# M6 — Item Photos (sub-plan)

Date: 2026-07-19 · Status: locked for implementation (post-M5) · Slice of M6
(ccv4-plan.md §4, the "item photos (CKAsset)" line). Runs after the M5 human
gate; does not block M2–M5.

**Repo-verified 2026-07-19 against `main` @ f57cb41.** Confirmed before locking:
last migration is `v3` (so photos add `v4`); on-disk store is `DatabasePool`
(WAL); `items.photo_asset_ref` is already read/written in `RecordMapper` (lines
59/141); `Container` has no cover field yet; `SyncRecordType.parentsFirst` =
`[.room, .category, .container, .item]` (P10's FK-cycle concern is real);
`ParsedServerRecord` is a pure `Equatable, Sendable` value `{ row, systemFields }`
and `RecordMapper.parse` is a pure function; the orphan buffer serializes
`ParsedServerRecord` to disk (`OrphanedRecord`) and reloads it in `drainOrphans`;
`applyWithMerge(_:)` consumes the pure `ParsedServerRecord`. These facts drive
P8/P9 below — read them before P8.

## 1. Scope

One optional photo per item, captured from camera or library, shown as a
thumbnail beside each item in a container and full-screen on tap. A container
may display a **user-designated** cover item's photo in room/container lists.
No AI cataloging (stays M7).

Decisions locked with Owen (2026-07-19):
- **P1** — One photo per item. Single nullable ref; no photo child table.
- **P2** — Capture from camera *and* photo library.
- **P3** — Sequenced after M5 (real family data already in Production).
- **P4** — Container cover = user-designated item (Variant A). Variant B
  (a dedicated photo of the container itself) deferred → OPEN_ITEMS (FU1).
- **P5** — Authorship unaffected; D11 (`created_by`) unchanged.

## 2. Decisions & rationale

- **P6 — `items.photo_asset_ref` is a device-independent photo id, not a path.**
  A fresh uppercase-UUID id is minted on every set/replace, nil on clear. It
  stays an ordinary synced row field (already mapped, verified), so
  `ServerApply` verbatim writes and LWW (DL20/DL21) keep working unchanged:
  replacing a photo changes the id → LWW sees an edit → peers re-pull. The
  column already exists (migration v1); only its *meaning* is defined here — no
  `Item` struct change, no item migration.
- **P7 — Bytes ride as a CKAsset field `photo` on the Item record**, separate
  from the row fields. Local file of record:
  `Application Support/Photos/<photo_asset_ref>.jpg`. CloudKit is source of
  truth; the local file is a cache/mirror. Nil ref → no asset, no file.
- **P8 — The one new inbound side-effect lives in the COORDINATOR, not the
  mapper (repo-corrected).** The original wording ("`parse` surfaces the CKAsset
  fileURL alongside the parsed row") would have added a mutable, non-pure
  `assetFileURL` to `ParsedServerRecord` — but that type is `Equatable,
  Sendable` and `parse` is deliberately pure (its header insists on it), and the
  struct is serialized to the orphan table, where a temp URL would be dead on
  reload. So instead: **`RecordMapper` is UNCHANGED on the inbound asset path.**
  The coordinator already holds the live `CKRecord` at fetch time
  (`handleFetchedRecordZoneChanges`, `modification.record`). At apply time it
  reads `(record["photo"] as? CKAsset)?.fileURL` directly from that record and,
  after the row is written by `applyWithMerge`, calls
  `PhotoStore.ensureLocalFile(for: id, copyingFrom: assetURL)` when the local
  file for that id is missing. The merge itself stays verbatim; the copy is a
  post-apply coordinator action keyed off the item id. This confines the new
  side-effect to exactly where DL20 wants it and preserves the mapper's purity
  invariant. (Outbound is different — see §4 — and stays in the mapper, because
  attaching `CKAsset(fileURL:)` is pure construction from a local file, no side
  channel.)
- **P9 — Orphan'd photo bytes are copied at BUFFER time, keyed by id (repo-
  corrected).** CKAsset `fileURL`s are temporary and the buffered
  `ParsedServerRecord` (persisted as `OrphanedRecord`, reloaded in
  `drainOrphans`) cannot carry a live URL. So when a photo'd item FK-orphans and
  is about to be buffered, the coordinator first copies its asset bytes into
  `Photos/<id>.jpg` via `PhotoStore.ensureLocalFile` (same call as P8), then
  buffers the pure row as today. Drain (`applyWithMerge` on the reloaded record)
  needs no asset knowledge — the file is already on disk under the id the row
  carries. No change to `OrphanedRecord`'s shape; the fix is a copy at the
  buffering seam in `handleFetchedRecordZoneChanges`/`applyServerBatch`, before
  the record is written to the orphan table.
- **P10 — Cover is `containers.cover_item_id`, a SOFT reference (no FK).** A
  hard FK container→item would cycle against the existing item→container FK in
  the verified parents-first apply order. It is a plain nullable TEXT column,
  synced as a normal container field, resolved at display time with graceful
  fallback (missing / not-yet-synced item → existing text+icon look, same
  spirit as NotInCatalog).
- **P11 — Cover cleanup on item delete is display-time, not schema-enforced.**
  Display already tolerates a dangling cover pointer (P10), so correctness needs
  nothing on delete. For tidiness/propagation, additionally do a tracked re-save
  of the container clearing `cover_item_id` when its cover item is deleted
  (mirrors DL22's category-clear-before-delete, same LocalMutation path) so
  peers don't retain a stale pointer. Recommended; if it complicates the delete
  path, drop it — display still degrades correctly.
- **P12 — Downscale + local thumbnail; never sync a second asset.** On import:
  fix orientation, downscale to ≤2048 px long edge, encode HEIC (JPEG fallback)
  ~0.8. The list thumbnail is generated on-device and cached locally
  (`Photos/<id>_thumb.jpg`), not stored in CloudKit. Keeps asset size and sync
  bandwidth low.
- **P13 — Missing-asset state is first-class.** Assets download separately from
  record metadata and can be absent for a while (or after a wipe). When
  `photo_asset_ref != nil` but the local file is missing, show a placeholder and
  let detail-open / pull-to-refresh trigger a refetch. Floor: a "re-download
  photos" affordance in Settings.
- **P14 — Schema deploy: fold the two empty fields into the NEXT Production
  deploy you're already doing (LOCKED — was §10 open sub-decision).** Given the
  DL37/DL38 pain (two separate "cannot create type in production schema"
  incidents), do **not** plan a second standalone Production deploy for photos.
  An unused CKAsset field and an unused string column cost nothing sitting in
  the schema. Add `photo` (CKAsset) to Item and `cover_item_id` (String) to
  Container to the Development schema now, exercise both once in Development so
  the field types JIT-create (DL38 rule: a deploy is only complete after every
  record-producing path has run once in Dev — here, save one item with a photo
  and set one container cover), and include them in the next scheduled Production
  deploy. *Fallback if that deploy has already passed by the time this ships:*
  the standalone post-M5 second deploy via the temporary Development-pinned build
  (entitlement + `CLOUDKIT_ENV_PRODUCTION` flipped in lockstep, never committed);
  the sync-identity fingerprint (DL30) absorbs the env hops. **Either way the
  deploy itself is Owen's step, never the agent's.**

## 3. Data model

- `items.photo_asset_ref` — semantics per P6 (column already present, migration
  v1). `Item.photoAssetRef` unchanged.
- `containers.cover_item_id TEXT` — new nullable column, no FK (P10). Add
  `Container.coverItemId: String?` + CodingKey `cover_item_id` (slot it beside
  the existing fields; the model currently ends at `createdBy`).
- **Migration v4**: `ALTER TABLE containers ADD COLUMN cover_item_id TEXT;`
  (additive, nullable, no backfill). No item migration. (v4 confirmed next.)

## 4. Sync / CloudKit

- **Item** record type gains field `photo` (CKAsset). **Container** record type
  gains field `cover_item_id` (String).
- **Outbound (`RecordMapper.record`) — stays in the mapper (pure construction):**
  - Item: keep `record["photo_asset_ref"] = item.photoAssetRef` (the id string,
    P6, already present at line 59) *and* attach `record["photo"] =
    CKAsset(fileURL:)` when a local full-size file exists for that id; both nil
    when the item has no photo. The mapper may take the resolved file URL as a
    parameter (from `PhotoStore.fileURL(for:)`) so it performs no filesystem
    lookup itself and stays pure — thread it in like the zone id is threaded.
  - Container: `record["cover_item_id"] = container.coverItemId`.
- **Inbound — NO mapper change (P8).** `RecordMapper.parse` continues to return
  the pure `ParsedServerRecord`; it reads `photo_asset_ref` as today (line 141)
  and parses the new `cover_item_id` container field into `Container.coverItemId`.
  It does **not** touch the CKAsset. The coordinator reads the CKAsset off the
  live `CKRecord` and does the P8 copy after apply / the P9 copy before buffering.
- **`ParsedServerRecord` is unchanged** — do not add `assetFileURL`.
- **Delete/replace cleanup:** on item delete or photo replace/clear, delete the
  now-orphaned local file(s) (`Photos/<oldId>.jpg` + `_thumb`). CKAsset deletion
  is implicit (record deleted, or `photo` set nil on next save) — no dangling
  CloudKit assets.

## 5. Storage & capture (local)

- **PhotoStore** (new, `Shared/PhotoStore.swift`): owns `Photos/` under
  Application Support. API ~ `importImage(_:) -> String` (mints id, processes per
  P12, writes full + thumb, returns id), `fileURL(for:)`, `thumbnailURL(for:)`,
  `ensureLocalFile(for:copyingFrom:)` (P8/P9 — copies only when the target file
  is missing, no-op otherwise), `delete(id:)`. Pure file/image work, no CloudKit
  knowledge. Thumbs are regenerable from the full image. Make it `Sendable` and
  concurrency-clean (it's called from the coordinator actor's apply path).
- **Capture UI:** SwiftUI `PhotosPicker` for library (no permission). Camera via
  a small `UIViewControllerRepresentable` over `UIImagePickerController`
  (`.camera`). `NSCameraUsageDescription` already ships for the scanner — **no
  plist change**. Source chooser (Camera / Library / Remove) on the editor.

## 6. Display

- **ItemEditorView:** photo section at top — current photo or "Add Photo", tap →
  source chooser; Replace / Remove. When the item has a photo, a "Set as
  Container Cover" row writes `cover_item_id = item.id` via container
  LocalMutation; show a "Cover" check when this item is already the cover.
- **ItemRow (ContainerDetailView):** leading thumbnail (rounded, ~44 pt) when
  present; placeholder per P13 when ref present but file missing; unchanged
  layout when no photo. This is the literal ask.
- **Full-screen:** tap the row thumbnail → zoomable full image; missing →
  placeholder + refetch.
- **Container lists (Rooms → containers):** show the cover item's thumbnail when
  `cover_item_id` is set and resolvable; else current look (P10 fallback).
- **Search results:** item thumbnail beside name+location — include if cheap,
  else fast-follow.

## 7. Tests (Swift Testing)

- Migration v4 additive; existing rows get `cover_item_id = NULL`; v1–v3 still
  apply in order.
- Mapper round-trip: item with a photo id → CKRecord (has the `photo_asset_ref`
  string field *and*, given a file URL, a `photo` CKAsset) → parse → same id
  back, `ParsedServerRecord` still pure/Equatable; container `cover_item_id`
  round-trips. (The asset *copy* is coordinator-level, not asserted here.)
- PhotoStore: import writes full+thumb, downscales ≤2048, fresh id per import;
  delete removes both files; `ensureLocalFile` copies when missing, no-ops when
  present.
- Cover resolution: set → resolves; cover item deleted → fallback (no crash);
  P11 tracked re-save clears the pointer.
- LWW: replacing a photo (id change) beats an older edit; photoless-vs-photo'd
  converges on latest.
- CKAsset upload/download is device-only (VERIFY), not a unit test.

## 8. VERIFY

Agent-verifiable: build + tests green; migration test; mapper / PhotoStore /
cover tests; simulator screenshots of an item with a photo, a container list
showing a cover, and the missing-photo placeholder.

Human, on-device (post-M5, ≥2 accounts):
- Add a photo on Owen's phone (camera *and* library) → appears on Shelley's
  within seconds; full-screen loads.
- Replace the photo → peer updates to the new image (LWW).
- Designate a cover on one device → container list shows it on both.
- Delete the cover item → container falls back gracefully on both.
- Wipe/reinstall a device, resync → photos re-download (P13); the "re-download
  photos" affordance works.
- Cross-check any CKAsset weirdness on Shelley's stable-OS device before
  suspecting app code (standing rule, M4 / DL19).

## 9. Touch-list

- `Data/Models/Container.swift` (+`coverItemId` + CodingKey `cover_item_id`)
- `Data/Database/AppDatabase.swift` (migration v4)
- `Shared/PhotoStore.swift` (new — regenerate project after adding)
- `Sync/RecordMapper.swift` — **outbound only**: item `photo` CKAsset attach
  (file URL threaded in); container `cover_item_id` both ways. **No
  `ParsedServerRecord` change; no inbound asset handling here (P8).**
- `Sync/SyncCoordinator.swift` — inbound CKAsset side-effect: read
  `(record["photo"] as? CKAsset)?.fileURL` off the live record in
  `handleFetchedRecordZoneChanges`; P8 copy after `applyWithMerge`; P9 copy
  before buffering an orphan; delete/replace local-file cleanup.
- Container repository (cover set/clear via LocalMutation; P11 tracked re-save)
- `Features/Items/ItemEditorView.swift` (photo control + source chooser +
  set-as-cover)
- `Features/Containers/ContainerDetailView.swift` (ItemRow thumbnail;
  full-screen)
- Rooms → containers list view (cover thumbnail)
- `Features/Search/…` (thumbnail — optional)
- `Features/Settings/…` (re-download photos affordance, P13 floor)
- `ClutterCatcherTests` (§7)
- `project.yml`: no plist change; regenerate after adding `PhotoStore.swift`.

## 10. Open sub-decisions (non-blocking)

- ~~Fold empty fields into an earlier deploy?~~ **Locked as P14** — yes, fold
  into the next Production deploy; standalone second deploy is the fallback only.
- **Auto-designate the first photo added in a coverless container as its cover**
  (user still overrides)? Reduces friction. Default = manual only (matches P4).
  Left to Owen; interim = manual.
