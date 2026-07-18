# M0 + M1 Implementation Plan (Run 1)

Status: executed in this run. Authoritative spec: `planning/ccv4-plan.md` (the plan wins on conflict).

## Scope

M0 (scaffold) + M1 (complete local app). No CloudKit code beyond entitlements/scaffold.
Local-only tables for sync (`settings`, `sync_state`, `record_metadata`, `pending_changes`)
are created now, used starting M2.

## File tree

```
project.yml                     # XcodeGen source of truth — never hand-edit the .xcodeproj
scripts/build.sh                # xcodegen generate + xcodebuild build (honors DEVELOPER_DIR)
scripts/test.sh                 # xcodegen generate + xcodebuild test  (honors DEVELOPER_DIR)
scripts/ui-smoke.sh             # simulator walkthrough: boot, install, deep link, screenshots
ClutterCatcher/
  App/
    ClutterCatcherApp.swift     # @main, DB bootstrap, seed, onOpenURL → Router
    RootView.swift              # TabView: Rooms · Scan · Search · Family · Settings
    Router.swift                # @Observable tab + NavigationPath state, deep-link handling
  Data/
    Database/AppDatabase.swift  # DatabaseWriter wrapper, migrator (schema v1), observation helpers
    Models/Room.swift ·  Category.swift · Container.swift · Item.swift
    Models/LocalRecords.swift   # Setting, SyncState, RecordMetadata, PendingChange (M2 consumers)
    Repositories/RoomRepository.swift · CategoryRepository.swift ·
                 ContainerRepository.swift · ItemRepository.swift · SearchRepository.swift
    Seed/SeedData.swift         # fixed compiled-in UUIDs (D12)
    Seed/Seeder.swift           # first-launch flag + idempotent INSERT OR IGNORE
  Features/
    Rooms/RoomsHomeView.swift · RoomDetailView.swift · RoomEditorView.swift
    Containers/ContainerDetailView.swift · ContainerEditorView.swift
    Items/ItemEditorView.swift
    Categories/CategoriesView.swift · CategoryEditorView.swift
    Search/SearchView.swift
    Scan/ScanView.swift         # VisionKit DataScannerViewController + manual-entry fallback
    Scan/DataScannerRepresentable.swift
    Labels/LabelSheetSpec.swift # Avery-style grid presets + pure layout math (testable)
    Labels/LabelPDFRenderer.swift  # UIGraphicsPDFRenderer pagination
    Labels/LabelSheetView.swift # container picker, preview (PDFKit), print/share
    Labels/QRCodeGenerator.swift   # CoreImage, correction level Q
    Family/FamilyView.swift     # M3 placeholder
    Settings/SettingsView.swift
  Design/Tokens.swift           # placeholder Liquid Glass-era tokens, marked for replacement
  Shared/QRPayload.swift        # cluttercatcher://c/<uuid> format/parse (+ bare UUID)
  Shared/DeepLink.swift         # URL → Route
  Resources/Assets.xcassets     # AppIcon placeholder, AccentColor
ClutterCatcherTests/
  MigrationTests.swift · RepositoryTests.swift · SeedTests.swift ·
  QRPayloadTests.swift · DeepLinkTests.swift · LabelLayoutTests.swift
```

## Schema DDL (migration `v1`, plan §3.1)

Synced tables — `id TEXT PRIMARY KEY` (UUIDv4 uppercase string = future CKRecord recordName),
`created_at`/`updated_at` DATETIME, `created_by TEXT` nullable (populated by sync in M2+):

- `rooms` — `name TEXT NOT NULL`, `sort_order INTEGER NOT NULL DEFAULT 0`, `icon TEXT`
- `categories` — `name TEXT NOT NULL`, `color_token TEXT NOT NULL DEFAULT 'gray'`
- `containers` — `room_id` FK → rooms ON DELETE CASCADE, `name TEXT NOT NULL`,
  `notes TEXT`, `label_slot INTEGER` nullable
- `items` — `container_id` FK → containers ON DELETE CASCADE, `name TEXT NOT NULL`,
  `quantity INTEGER NOT NULL DEFAULT 1`, `notes TEXT`,
  `category_id` FK → categories ON DELETE SET NULL, `photo_asset_ref TEXT` (M6)

Local-only:

- `settings` — `key TEXT PRIMARY KEY`, `value TEXT NOT NULL`
- `sync_state` — `key TEXT PRIMARY KEY`, `data BLOB NOT NULL` (engine state / change tokens)
- `record_metadata` — `record_id TEXT PRIMARY KEY`, `record_type TEXT NOT NULL`,
  `system_fields BLOB NOT NULL` (archived CKRecord system fields)
- `pending_changes` — `record_id TEXT PRIMARY KEY`, `record_type TEXT NOT NULL`,
  `change_kind TEXT NOT NULL` ('save' | 'delete'), `queued_at DATETIME NOT NULL`

Indexes: `containers.room_id`, `items.container_id`, `items.category_id`. Foreign keys ON.

## Screen inventory

Rooms home (list + counts, reorder, add) → Room detail (containers) → Container detail
(items, QR preview, print single label) → Item editor. Categories (list/editor with color
tokens). Search (rooms/containers/items/categories, grouped). Scan (camera on device,
manual entry on simulator, friendly not-found). Labels (sheet spec picker, container
multi-select, PDF preview, print/share). Family (placeholder). Settings (stats, seed
status, version, destructive reset behind confirmation).

## Test list

1. Migration: fresh DB migrates; all 8 tables + expected columns; FKs enforced.
2. Repositories: CRUD each entity; Room delete cascades containers→items; category
   delete nulls `items.category_id`; timestamps update; sort_order reorder.
3. Seed: applies once; re-run adds nothing; fixed UUIDs present; flag set; partial-seed
   recovery (flag missing, rows present) stays duplicate-free.
4. QRPayload: format→parse round-trip; bare UUID; lowercase input; garbage rejected;
   `r/` rooms reserved form parses as `.room`.
5. DeepLink: `cluttercatcher://c/<uuid>` → container route; unknown host → nil; case
   handling.
6. Label layout: cells-per-sheet, pagination count, cell rects inside page bounds,
   no overlap, slot→page/cell mapping.

## Environment note (this run)

This run executed in a Linux container (no Xcode/Swift toolchain). Everything
machine-checkable here was checked (schema DDL + cascade semantics proven against real
SQLite via Python, project.yml/plist/asset JSON validated, layout math cross-checked).
`xcodegen generate`, `xcodebuild build/test`, and the simulator walkthrough are Owen's
first `scripts/*.sh` runs on the Mac — see VERIFY report + OPEN_ITEMS.
