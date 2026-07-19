# M4 — Make It Yours (themes + personalization) — rewritten milestone

Date: 2026-07-19 · Status: **locked for implementation** · Supersedes the
original M4 ("Shelley" install gate) in `ccv4-plan.md` §4 · Runs **after
M6.1** (HEIC + GC) completes.

## 1. Context & provenance

Shelley designed a full five-theme system for ClutterCatcher in her own
Claude Design session. Three canvases, committed under `design/reference/`:

- **Current App** — faithful recreation of today's app (iOS 26 light, accent
  `#E09140`). The honest baseline every diff is measured against.
- **Theme Explorations** — the system: five themes on one token structure,
  six app icons (Classic default + one per theme), Fen mascot direction.
- **Pop Lead Screens** — the lead theme's key screens, light + dark, plus
  the App Icon picker and the Settings "Make It Yours" section.

The design's core contract: **one skeleton, five outfits.** Every theme
fills the same token roles over the untouched Liquid Glass substrate;
layout, navigation, and behavior never change between themes. Each theme
ships light + dark. Theme and icon are **per-device, per-person** — never
synced, never forced on anyone.

### Why M4 was rewritten

The original M4 ("install on Shelley's iPhone, real invite, real
acceptance") was overtaken by events: Shelley has been a live participant
since the M3 gate, and cross-account CKAsset sync was verified on her
device 2026-07-19 (DL50). What remains live from old M4 folds into this
milestone's human gate:

- the deliberate **offline conflict script** (both edit the same item →
  LWW confirmed, receipts visible in Sync Activity — DL28),
- the **one-week parallel-use soak**, now on an app Shelley has personal
  stake in,
- **Shelley's sign-off**, and
- the standing **stable-device control rule** (her iOS 26 phone checks any
  weirdness seen on Owen's iOS 27 beta phone first — DL19).

M5 (Andrew + Michael) stays a separate milestone **after** this one lands —
Arcade is the carrot for the kids' onboarding.

## 2. Decisions (T-series)

- **T1 — Themes are values.** A `Theme` type carrying two `Palette`s
  (light + dark) plus identity (id, display name, matching icon name,
  Fen presence, motion personality). Six built-ins: **Classic** (today's
  look — system backgrounds, accent `#E09140`, no Fen, default motion),
  **Cozy Home**, **Pop!**, **Fresh**, **Arcade**, **Dusk Redux**. Classic
  is the default forever; a user who never opens the picker sees no change.
- **T2 — Per-device persistence, zero sync surface.** The selected theme id
  lives in the local-only `settings` table under a `theme_id` key, written
  via the plain settings path (DL20 — nothing to stamp or queue). The app
  icon is system state (`UIApplication.setAlternateIconName`); we never
  persist it ourselves. A test asserts theming operations produce **zero**
  `pending_changes` rows.
- **T3 — Token roles normalized.** Roles: `bg`, `surface`, `accent`,
  `accent2`, `accent3` (optional), `text`, `success` (optional). Mapping
  from Shelley's sheets: Fresh's `sage` → accent2, `berry` → accent3;
  Dusk's `amber` → accent2. Fallbacks where a sheet omits a role:
  Pop! `success` → accent2 (teal); Fresh `success` → accent. Destructive/
  warning stay system semantic colors in every theme.
- **T4 — System appearance is respected, never forced.** Every theme
  defines both palettes and follows the device light/dark setting. Arcade
  is *dark-first by identity*: its dark palette is the indigo-night set,
  its light palette the soft-lavender day-mode. No
  `preferredColorScheme` overrides.
- **T5 — Liquid Glass substrate untouched.** Themes tint content: view
  backgrounds, cards, chips, accents via `.tint`. System bars, sheets, and
  materials keep their native treatment. (This is what makes six themes
  cheap instead of six forks.)
- **T6 — SF Pro Rounded everywhere** via `.fontDesign(.rounded)` at the
  root (all themes, including Classic). System font — zero shipping cost.
- **T7 — App icons.** Six single-size 1024pt PNGs, pre-rendered from
  Shelley's icon SVGs (see §8 provenance), as appiconsets:
  `AppIcon` (Classic — replaces/confirms the existing icon art), plus
  `AppIcon-Hearth`, `AppIcon-FenWink`, `AppIcon-Sprout`,
  `AppIcon-NightSprite`, `AppIcon-Dusk`.
  `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_NAMES = YES` in `project.yml`.
  Changing theme **offers** the matching icon (inline prompt), never
  switches it silently; the icon picker allows any icon with any theme.
- **T8 — The lead-screen layout/copy refresh ships for all themes** (one
  skeleton — the refresh is theme-independent). Full list in §4.
- **T9 — Fen is drawn in SwiftUI shapes**, not image assets, from
  `design/fen-geometry.md` (geometry extracted from Shelley's SVGs; eyes
  are separate shapes by design so the blink is one animation). Presence
  dial per theme: Cozy *light touch*, Pop! *medium*, Arcade *full pixel
  sprite*, Fresh / Dusk Redux / Classic *none*. **M4a ships the empty-state
  Fen with idle blink** (guaranteed, per Owen); ear-perk, scan-card peek,
  and the pixel sprite are M4b.
- **T10 — Motion personality is a per-theme token set** (spring presets +
  reward-moment style; table in §6), implemented in M4b. All overshoot,
  confetti, and glow effects respect Reduce Motion (fall back to plain
  fades). Haptics ship (success notification on scan, soft impact on
  save); the mocks' "plink" **sound does not** — deferred until someone
  misses it.
- **T11 — Room accent cycle.** Pop! rotates its accent trio
  (bubblegum/teal/tangerine) across room icon tiles and room-scoped
  accents; every other theme cycles a single accent. Modeled as
  `Theme.accentCycle: [Color]` — index = stable function of the room's
  sort position, so colors don't shuffle when unrelated rooms change.
- **T12 — Chip tints are derived, not hardcoded**: accent over surface at
  ~12–14% opacity (matches Shelley's sampled chip colors within a hair),
  so category/room chips work in all twelve palettes for free.
- **T13 — Old-M4 residue is this milestone's human gate** (§1): conflict
  script + one-week soak + Shelley's sign-off close M4.
- **T14 — Amends D16.** Fen's "empty-state cameo only" becomes the per-theme
  presence dial above, and Dusk returns as an optional theme (Dusk Redux).
  Noted in `ccv4-plan.md`.

## 3. Token sheet

Extracted verbatim from Shelley's Theme Explorations swatches. Arcade's
"light" column is the lavender day-mode per T4.

### Cozy Home (icon: Hearth · Fen: light touch)
| role | light | dark |
|---|---|---|
| bg | `#F7F0E6` | `#241C15` |
| surface | `#FFFDF9` | `#322820` |
| accent | `#C4643C` | `#E08757` |
| accent2 | `#E3A455` | `#EFB968` |
| text | `#3B2E24` | `#F5EDE2` |
| success | `#7A9B5E` | `#95B478` |

### Pop! (lead · icon: Fen Wink · Fen: medium)
| role | light | dark |
|---|---|---|
| bg | `#FFF7EE` | `#251C2E` |
| surface | `#FFFFFF` | `#332841` |
| accent | `#F0509B` | `#FF6FB0` |
| accent2 | `#00A8A0` | `#2CD1C8` |
| accent3 | `#FF8A3B` | `#FFA05C` |
| text | `#33253A` | `#FBEFF6` |
| success | → accent2 | → accent2 |

Dark note (Pop lead screens): plum-tinted neutrals, never pure black;
accents brighten one step for contrast — already reflected above.

### Fresh / Botanical (icon: Sprout · Fen: none)
| role | light | dark |
|---|---|---|
| bg | `#F4F3EA` | `#1C231D` |
| surface | `#FFFFFF` | `#28322A` |
| accent | `#4E7D52` | `#7FAE83` |
| accent2 (sage) | `#8FAE8B` | `#5A7A5E` |
| accent3 (berry) | `#A94F6D` | `#C97B95` |
| text | `#29352B` | `#EDF2EA` |
| success | → accent | → accent |

### Arcade (icon: Night Sprite · Fen: full pixel sprite · dark-first)
| role | light (lavender day) | dark (indigo night — the identity) |
|---|---|---|
| bg | `#EDEBFA` | `#17133A` |
| surface | `#FFFFFF` | `#241E52` |
| accent | `#C427A8` | `#FF4FD8` |
| accent2 | `#0798C4` | `#35E0FF` |
| text | `#241E52` | `#F0EEFF` |
| success | `#14935B` | `#5CFF9D` |

### Dusk Redux (icon: Dusk · Fen: none)
| role | light | dark |
|---|---|---|
| bg | `#F3F0FA` | `#1E1830` |
| surface | `#FFFFFF` | `#2A2342` |
| accent | `#6C4EC2` | `#9B7FE8` |
| accent2 (amber) | `#E09140` | `#F0A055` |
| text | `#2C2440` | `#EFEAFB` |
| success | `#55915F` | `#7FB58A` |

### Classic (icon: AppIcon · Fen: none)
System backgrounds/labels as today; accent `#E09140`; default motion.
Classic is "no theme" — it must remain pixel-equivalent to the current app
apart from the global rounded type (T6) and the layout refresh (T8).

## 4. Layout & copy refresh (T8 — all themes, from Pop Lead Screens)

- **Rooms home:** subtitle under the large title — "N rooms · N containers
  · everything has a home" (live counts); room icon tiles tinted from the
  theme's accent cycle (T11); Edit stays.
- **Rooms empty state:** "Let's give everything a home" + supporting line +
  "Add Your First Room" button; Fen figure where the theme's dial says so
  (blinking in M4a). Same pattern reserved for future "all filed" moments.
- **Container detail:** room + item-count as chips under the title;
  section header "Items" → **"Inside"**; category shown as tinted capsule
  chips (T12); added-by line kept (DL35).
- **Item editor:** category picker becomes a wrapping chip row (selected =
  filled accent, unselected = tinted); quantity as −/n/+ stepper per mock;
  notes placeholder "Anything worth remembering?".
- **Scan success:** full-card "Found it!" state — container name ·
  room · item count, "Open It Up" button. Card itself is M4a (static);
  its pop/confetti/Fen-peek personality is M4b.
- **Settings:** new **"Make It Yours"** section at top — Theme row
  (current theme name) and App Icon row (current icon name), footer
  "Theme and icon are yours alone — everyone in the family picks their
  own." Existing Catalog/About/Sync sections unchanged below it.
- **App Icon picker** (pushed from Make It Yours): 6-tile grid with
  labels, ring + check on the active icon, footer "Changing your theme
  offers the matching icon — it never switches on its own." Tap = instant
  swap (bounce animation is M4b).
- **Theme picker** (pushed from Make It Yours): one row/card per theme
  with name, one-line personality description, and a small swatch strip;
  selecting applies live and offers the matching icon (T7).

Explicitly **not** in scope: navigation changes, new tabs, any data-model
or sync change, iPad layout (M6).

## 5. Fen (T9)

Geometry: `design/fen-geometry.md` — ears, inner-ear shadows, head,
muzzle, eyes (+highlights), nose as plain SwiftUI `Shape`s in a 70×74
design space; wink and pixel variants included. Per-theme colors in the
same doc.

| Theme | Presence |
|---|---|
| Cozy Home | light touch — empty states only |
| Pop! | medium — empty states + peeks over the scan-success card (M4b) |
| Arcade | full — pixel-sprite Fen in Scan + empty states, glow accents (M4b) |
| Fresh, Dusk Redux, Classic | none |

M4a: `FenFigure` view (open-eye base) with **idle blink** — eye circles
scale-Y toward ~0.1 and back, highlights fade during the closed phase,
randomized ~4–7 s cadence with occasional double blink; timer pauses when
not visible. M4b adds: ear perk on primary-button press, the wink, the
scan-card peek (Pop!), and the Arcade pixel sprite.

## 6. Motion personality (T10 — M4b)

| Theme | Springs | Reward moment (scan success / save) |
|---|---|---|
| Classic | system defaults | standard transitions, success haptic |
| Cozy Home | slow-honey (higher response, high damping), gentle settles | soft settle, no burst |
| Pop! | bouncy overshoot — scan pop `response .35, damping .6` | confetti-dot burst (once) + Fen peek; save = "drop-in" squash-settle + soft impact haptic |
| Fresh | quiet, damped | a leaf unfurls — no confetti |
| Arcade | snappy pops | glow pulse on the card, score-tick count-up on item count |
| Dusk Redux | system defaults, slightly softened | standard + success haptic |

Cross-cutting (M4b): staggered 30 ms spring-settle on Rooms first load;
icon-picker tile bounce on selection. **Reduce Motion:** every overshoot,
stagger, confetti, glow, and Fen animation degrades to a plain fade;
blink pauses entirely. Haptics per T10; no sounds.

## 7. Dispatches

### M4a — ThemeKit + Make It Yours *(agent-implementable, Owen-verified)*

Scope: `Theme`/`Palette` types + six themes (§3) in `Design/`
(`Tokens.swift` evolves rather than being replaced); environment plumbing
so every screen resolves colors through the active theme; rounded type
(T6); persistence + zero-sync guarantee (T2); layout/copy refresh (§4);
theme picker, Make It Yours section, App Icon picker + alternate icons +
`project.yml` setting (T7); `FenFigure` with idle blink on empty states
per presence dial (§5); icon PNGs copied from `design/icons/` into the
asset catalog.

Tests: palette completeness for all six themes (every role resolvable,
both appearances); theme persistence round-trip; **zero `pending_changes`
from theme + icon-name operations**; accent-cycle stability under room
reordering; icon-name mapping (theme → appiconset name, including nil for
Classic/primary).

**VERIFY (agent):** `xcodegen generate` → build → tests green · simulator
screenshot set: Rooms, container detail, item editor, scan (manual-entry
fallback), Settings + both pickers — in Pop! light, Pop! dark, Arcade
dark, Cozy light minimum · Classic unchanged side-by-side vs current.
**VERIFY (Owen, on device):** switch through all six themes live — no
restart, no layout shift · icon swap applies from the picker (home screen
check, dark wallpaper too) · theme survives relaunch · Fen blinks on the
empty state (visit a fresh category/search state or temp-empty room) ·
Shelley picks her theme on her phone — **her choice does not appear on
Owen's device, and Sync Activity stays quiet.**

### M4b — Motion & Fen personality + the family gate *(agent-implementable, human gate)*

Scope: motion token set + per-theme personalities (§6); reward moments;
Fen ear-perk, wink, scan-card peek, Arcade pixel sprite; icon-picker
bounce; Reduce Motion audit; haptics.

**VERIFY (agent):** tests green (motion tokens resolve per theme; Reduce
Motion flag switches implementations) · sim capture of the scan-success
pop in Pop! and Arcade.
**VERIFY (human — closes M4):**
1. Motion personality distinct across Pop!/Cozy/Arcade on device; Reduce
   Motion honored (Settings → Accessibility toggle).
2. **Conflict script** (old M4): Owen + Shelley both edit the same item
   offline → reconnect → LWW resolves, nothing lost silently, receipts
   visible in **both** phones' Sync Activity.
3. **One-week soak** of genuine parallel use on themed builds; any
   weirdness on Owen's iOS 27 beta phone cross-checked on Shelley's
   stable device first (DL19).
4. **Shelley signs off.** M4 closes; M5 (Andrew + Michael, Arcade in
   hand) opens.

## 8. Asset provenance & touch-list

Icons were rendered by Claude (chat) 2026-07-19 at 1024×1024 directly from
the SVG glyph + tile-gradient definitions in Shelley's Theme Explorations
doc (full-bleed square; iOS masks corners). Sources + PNGs live in
`design/icons/` (SVGs are the editable source of truth; `contact-sheet.png`
for a quick eyeball). Reference canvases in `design/reference/` open in a
browser as-is.

Touch-list:
- `Design/Theme.swift` (new), `Design/Tokens.swift` (evolves),
  `Design/Motion.swift` (M4b), `Shared/FenFigure.swift` (new)
- `Features/Settings/SettingsView.swift` (Make It Yours) + new
  `Features/Settings/ThemePickerView.swift`, `AppIconPickerView.swift`
- §4 touches: `RoomsHomeView`, `RoomDetailView`, `ContainerDetailView`,
  `ItemEditorView`, `ScanView`, `SearchView`, editors' chip rows
- `Resources/Assets.xcassets`: 5 new appiconsets + updated `AppIcon`
- `project.yml`: `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_NAMES` →
  regenerate
- `ClutterCatcherTests`: §7 tests
- `OPEN_ITEMS.md`: log as DL-entries (start after M6.1's allocations)

## 9. Non-goals

No sync-contract, schema, or CloudKit change of any kind; no CloudKit
Console step exists in this milestone. No appearance forcing. No custom
fonts. No sounds. No per-room user-chosen colors (accent cycle is
automatic). No iPad layout (M6). No theme sync — per-device is the
feature, not a limitation.
