# Fen — geometry reference (for SwiftUI port)

Source: Shelley's `Theme Explorations.dc.html` icon glyphs (cards 2b/2c/2e).
Fen is flat geometric shapes, no outlines. Canvas/viewBox: `7 3 70 74`
(x, y, w, h) — treat as a 70×74 design space; scale to fit.

All coordinates below are in that design space. Colors are per-theme
(the shapes recolor; geometry never changes).

## Base face (open eyes — "Hearth" variant)

| # | Shape | Geometry | Role / theme color |
|---|-------|----------|--------------------|
| 1 | polygon | `18,34 24,8 42,26` | left ear — body color |
| 2 | polygon | `66,34 60,8 42,26` | right ear — body color |
| 3 | polygon | `21.5,30 25.5,14 36,25` | left inner ear — text color @ 25–45% opacity |
| 4 | polygon | `62.5,30 58.5,14 48,25` | right inner ear — text color @ 25–45% opacity |
| 5 | circle | c=(42,48) r=26 | head — body color |
| 6 | ellipse | c=(42,58) rx=15 ry=12 | muzzle — muzzle color (near-white/cream) |
| 7 | circle | c=(33,45) r=3.2 | **left eye** — eye color (dark) |
| 8 | circle | c=(51,45) r=3.2 | **right eye** — eye color (dark) |
| 9 | circle | c=(34.2,43.8) r=1 | left eye highlight — white |
| 10 | circle | c=(52.2,43.8) r=1 | right eye highlight — white |
| 11 | ellipse | c=(42,53) rx=3 ry=2.4 | nose — eye color (dark) |

## Wink variant ("Fen Wink" icon)

Right eye (#8) and its highlight (#10) are replaced by a stroked arc:

```
path: M47.8 45.5 c 1.6,-2 4.8,-2 6.4,0
stroke: eye color, width 2.6, round cap, no fill
```

## Pixel variant ("Night Sprite" / Arcade)

Eyes and nose become squares/rects (no highlights):

| Shape | Geometry | Role |
|-------|----------|------|
| rect | x=29.5 y=41.5 w=6 h=6 | left eye — accent2 (cyan) |
| rect | x=48.5 y=41.5 w=6 h=6 | right eye — accent2 (cyan) |
| rect | x=39.5 y=51 w=5 h=4.5 | nose — bg color (indigo) |

Arcade icon adds a glow: drop-shadow 0 0 ~7pt (at 120pt tile) in accent
@ 55% — in-app, use a soft shadow in accent, scaled to render size.

## Blink (M4a requirement)

Eyes are separate shapes precisely so the blink is one animation:
scale the eye circles' Y toward ~0.1 (anchor at eye center) and back —
highlight dots fade out during the closed phase. Idle cadence: blink
every ~4–7 s (randomized), double-blink occasionally. Ear perk (M4b):
briefly rotate/translate ears up ~4° on button press.

## Per-theme Fen colors

| Theme | body | muzzle | eyes/nose | inner-ear opacity |
|-------|------|--------|-----------|-------------------|
| Cozy Home | #C4643C | #FFF6EC | #2E2015 | 35% |
| Pop! | #FFF7EE (cream) | #FFFFFF | #33253A | 25% |
| Arcade | #FF4FD8 | #FFC9EC | pixel cyan #35E0FF / nose #17133A | 45% |

Fresh, Dusk Redux, Classic: no Fen (presence dial = none).
