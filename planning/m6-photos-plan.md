# M6 — Item Photos (sub-plan)

Date: 2026-07-19 · Status: locked for implementation (post-M5) · Slice of M6
(ccv4-plan.md §4, the "item photos (CKAsset)" line). Runs after the M5 human
gate; does not block M2–M5.

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
  stays an ordinary synced row field, so `ServerApply` verbatim writes and LWW
  (DL20/DL21) keep working unchanged: replacing a photo changes the id → LWW
  sees an edit → peers re-pull. The column already exists (migration v1); only
  its *meaning* is defined here — no `Item` struct change, no item migration.
- **P7 — Bytes ride as a CKAsset field `photo` on the Item record**, separate
  from the row fields. Local file of record:
  `Application Support/Photos/<photo_asset_ref>.jpg`. CloudKit is source of
  truth; the local file is a cache/mirror. Nil ref → no asset, no file.
- **P8 — Inbound gains one side-effect on top of verbatim apply.**
  `RecordMapper.parse` surfaces the CKAsset `fileURL` alongside the parsed row;
  the apply path, after writing the item row, ensures `Photos/<id>.jpg` exists
  by copying the asset file when the local file for that id is missing. Nothing
  else in `ServerApply` changes.
- **P9 — Orphan buffer copies asset bytes at buffer time, not drain time**
  (extends DL24/DL36). CKAsset `fileURL`s are temporary; a photo'd item that
  FK-orphans must copy its bytes into `Photos/<id>.jpg` when buffered, because
  the serialized `SyncedRow` in `orphaned_records` cannot hold a temp URL that
  will be gone by drain. Drain then just writes the row (file already present).
- **P10 — Cover is `containers.cover_item_id`, a SOFT reference (no FK).** A
  hard FK container→item would cycle against the existing item→container FK in
  the parents-first apply order (`SyncRecordType.parentsFirst`). It is a plain
  nullable TEXT column, synced as a normal container field, resolved at display
  time with graceful fallback (missing / not-yet-synced item → existing
  text+icon look, same spirit as NotInCatalog).
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

## 3. Data model

- `items.photo_asset_ref` — semantics per P6 (column already present, migration
  v1). `Item.photoAssetRef` unchanged.
- `containers.cover_item_id TEXT` — new nullable column, no FK (P10). Add
  `Container.coverItemId: String?` + CodingKey `cover_item_id`.
- **Migration v4**: `ALTER TABLE containers ADD COLUMN cover_item_id TEXT;`
  (additive, nullable, no backfill). No item migration.

## 4. Sync / CloudKit

- **Item** record type gains field `photo` (CKAsset). **Container** record type
  gains field `cover_item_id` (String).
- **Outbound (`RecordMapper.record`):**
  - Item: keep `record["photo_asset_ref"] = item.photoAssetRef` (the id string,
    P6) *and* attach `record["photo"] = CKAsset(fileURL:)` when a local file
    exists for that id; both nil when the item has no photo.
  - Container: `record["cover_item_id"] = container.coverItemId`.
- **Inbound (`RecordMapper.parse`):**
  - Item: read `photo_asset_ref` as today; additionally surface
    `(record["photo"] as? CKAsset)?.fileURL`.
  - Container: parse `cover_item_id`.
- **`ParsedServerRecord`** gains `var assetFileURL: URL?` (nil for non-item /
  photoless). Coordinator apply copies it per P8; orphan buffer per P9.
- **Delete/replace cleanup:** on item delete or photo replace/clear, delete the
  now-orphaned local file(s) for the old id. CKAsset deletion is implicit (record
  deleted, or `photo` set nil on next save) — no dangling CloudKit assets.
- **Production schema deploy (post-M5):** adding `photo` (CKAsset) and
  `cover_item_id` after real family data exists is a *second* Production deploy.
  Per DL38, it is only complete after the new fields are exercised once in
  Development: in a temporary Development-pinned build (entitlement +
  `CLOUDKIT_ENV_PRODUCTION` flipped in lockstep, never committed — the DL38
  ritual), save one item with a photo and set one container cover so both field
  types are JIT-created in Dev, then flip back and deploy to Production. The
  sync-identity fingerprint (DL30) absorbs the env hops (reset → re-upload → LWW
  converge, catalog untouched). **This step is Owen's**, not the agent's.
  - *Alternative Owen may elect before M4:* fold the two empty fields into M4's
    Production deploy (an unused CKAsset/string field costs nothing) so this
    slice needs no second deploy. See OPEN_ITEMS sub-decision.

## 5. Storage & capture (local)

- **PhotoStore** (new, `Shared/`): owns `Photos/` under Application Support.
  API ~ `importImage(_:) -> String` (mints id, processes per P12, writes full +
  thumb, returns id), `fileURL(for:)`, `thumbnailURL(for:)`,
  `ensureLocalFile(for:copyingFrom:)` (P8), `delete(id:)`. Pure file/image work,
  no CloudKit knowledge. Thumbs are regenerable from the full image.
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

- Migration v4 additive; existing rows get `cover_item_id = NULL`.
- Mapper round-trip: item with photo id → CKRecord (string field + CKAsset
  present) → parse → same id + `assetFileURL` surfaced; container
  `cover_item_id` round-trips.
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

- `Data/Models/Container.swift` (+`coverItemId`)
- `Data/Database/AppDatabase.swift` (migration v4)
- `Shared/PhotoStore.swift` (new)
- `Sync/RecordMapper.swift` (item `photo` CKAsset both ways; container
  `cover_item_id`; `ParsedServerRecord.assetFileURL`)
- `Sync/SyncCoordinator.swift` (apply copies `assetFileURL` per P8; orphan buffer
  per P9; delete/replace file cleanup)
- Container repository (cover set/clear via LocalMutation; P11 tracked re-save)
- `Features/Items/ItemEditorView.swift` (photo control + source chooser +
  set-as-cover)
- `Features/Containers/ContainerDetailView.swift` (ItemRow thumbnail;
  full-screen)
- Rooms → containers list view (cover thumbnail)
- `Features/Search/…` (thumbnail — optional)
- `ClutterCatcherTests` (§7)
- `project.yml`: no plist change; regenerate after adding `PhotoStore.swift`.

## 10. Open sub-decisions (non-blocking)

- **Fold empty `photo`/`cover_item_id` fields into M4's Production deploy?**
  Avoids a second deploy. Owen decides before M4; default = separate post-M5
  deploy.
- **Auto-designate the first photo added in a coverless container as its cover**
  (user still overrides)? Reduces friction. Default = manual only (matches P4).
