# "hello" Theme & Launch-Time Theming — Design

**Date:** 2026-06-04
**Branch:** `new-graphics`
**Status:** approved in brainstorm (visual companion session, option A colors / hard shadow / monochrome shader tune)

## Goal

Restyle Ziel van Sebastian after the original Macintosh "hello." aesthetic — off-white
on very dark gray with a hard offset drop shadow — implemented as a **theme**, selected
at launch, so the current green/amber CRT look is preserved as a second theme.

## Non-goals / invariants

- **No face geometry changes.** `FaceGeometry.swift` is locked; `testLockedGeometry` must stay green.
- **No animation changes.** `FaceAnimation` and `Director` phase/tint *logic* are untouched
  (only the tint *values* they consume change with the theme).
- **No Metal shader code changes.** Only shader *parameter values* differ per theme.
- **`classic` renders pixel-identical to today.** The theme system must not alter the
  existing look in any way when `classic` is active.

## Theme model

A theme is a complete, named preset for the `look` configuration: tints, font,
background, shadow, and CRT shader parameters. Two built-in themes are defined in
`Sources/Core` (no theme files on disk):

| Key | `classic` (today's look) | `hello` (new) |
|---|---|---|
| `idleTint` | `#41ff6a` (green) | `#8a877c` (dim warm gray) |
| `thinkingTint` | `#ffb000` (amber) | `#c9c5b8` (mid off-white) |
| `speakingTint` | `#e6edf5` (white) | `#efeadd` (paper white) |
| `fontName` | `Menlo-Bold` | `Menlo-Bold` |
| `background` | `#030303` (current 0.012 clear color) | `#26271f` (unlit-phosphor gray) |
| `shadowColor` | none (shadow disabled) | `#0e0f0b` |
| `shadowOffsetX` / `shadowOffsetY` | 0 / 0 | 0.6 / 0.75 (face-grid pixels, down-right) |
| `shader.maskIntensity` | 0.25 | 0.0 (monochrome CRT — no RGB triads) |
| `shader.bloomStrength` | 0.55 | 0.4 |
| `shader.*` (all others) | current defaults | same as classic |

Other shader defaults (both themes): `scanlineIntensity` 0.35, `scanlinePitch` 3,
`curvature` 0.12, `vignette` 0.35, `flicker` 0.03, `noise` 0.04, `persistence` 0.82.

State coding in `hello` is **brightness-only** (brainstorm option A): dim idle,
mid thinking, bright speaking. The existing `Director` rules give the rest for free:
waking/settling lerp between tints (brightness ramps), offline is `idleTint × 0.45`
(≈ `#3e3c37`, barely lit but readable).

## Selection & override resolution

1. **Base:** built-in theme named by `look.theme` in `config.json`. Default: **`hello`**.
2. **CLI:** a `--theme <name>` launch argument overrides `look.theme` (handy for
   `make run` demos; the appliance normally uses config). It swaps the base theme only.
3. **Overrides:** any other key explicitly present in the config `look` block
   (e.g. `idleTint`, `shader.bloomStrength`) wins over the active theme's value,
   regardless of which theme is active or how it was selected.

Unknown theme names (from config or CLI) fail at startup with a clear error listing
the valid names — never a silent fallback.

### Config schema changes

- `LookConfig` and `ShaderConfig` change from "defaults inline" to **partial overlays**:
  every field optional at decode time, `nil` meaning "use the theme's value". A resolved
  look (theme + overlay) is computed once at startup and passed to the renderer/director
  as today.
- New `look` keys: `theme` (string), `background`, `shadowColor`,
  `shadowOffsetX`, `shadowOffsetY`. Shadow offsets are in **face-grid pixels**
  (the pixel-art unit, `FaceTransform.gridPixel`), not device pixels: a fixed
  device-pixel offset would vanish on a retina/4K drawable, while grid units keep
  the approved mockup proportions (~3.5% / 4.5% of face size) at any resolution.
- `config.example.json`: `look` block reduced to `{"theme": "hello"}` so the example no
  longer duplicates (and silently pins) theme values. Override usage is documented in the
  README Themes section instead (JSON allows no comments).

## Rendering changes

- **Background:** `ZielRenderer`'s hardcoded scene clear color is replaced by the resolved
  `background`. CRT intermediate passes (phosphor/bloom buffers) keep clearing to black;
  the area outside the barrel curvature stays black (reads as the tube edge).
- **Hard drop shadow** (the one code change, in `ScenePass`): when the resolved look has a
  shadow (offset ≠ 0), the face rects and every glyph quad (RSVP words and hint text) are
  drawn **twice**: first translated by the shadow offset in `shadowColor`, then the normal
  foreground pass on top. The thinking sweep band is **not** shadowed (it is a light
  effect, not an object). With no shadow defined (`classic`), the shadow pass is skipped
  entirely — zero rendering difference from today.
- **Known interaction, accepted:** phosphor persistence (`max(scene, prev × decay)`)
  makes a newly appeared word's shadow take ~5 frames (~80 ms) to reach full darkness.
  Imperceptible at RSVP pace and on-theme.

## Testing

All in CoreTests (platform-free):

- Theme resolution: default is `hello`; `look.theme` selects; unknown name errors.
- Override precedence: explicit `look` keys beat theme values; absent keys fall through.
- `classic` equivalence: resolving `classic` with an empty overlay reproduces today's
  exact values (pins the "don't lose the old look" guarantee).
- Decode: partial `look`/`shader` blocks, empty blocks, missing blocks.
- Existing config tests updated for the overlay change; `testLockedGeometry` untouched.

Rendering (shadow pass, background) is verified visually via `make run`, per project
convention — Metal code has no unit tests.

The `--theme` argument is parsed in the App target; keep the parsing trivial enough
that it needs no dedicated test beyond the resolution tests above.

## README & assets

After implementation:

- Add a **Themes** section to `README.md`: built-in themes (`hello`, `classic`),
  `look.theme` config key, `--theme` launch flag, override behavior.
- Recapture all five assets in `docs/screenshots/` in the `hello` theme
  (`idle.png`, `thinking.png`, `speaking.png`, `demo-crt.png`, `demo.gif`),
  same manual capture flow as v1 (windowed `make run` + macOS screen capture).
- Keep one `classic` screenshot in the Themes section so both looks are visible.

## Migration note

The user's real `config.json` (not in git) currently sets the old green/amber tints
in `look`. After this change those keys act as **overrides** and would pin the old
colors on top of any theme — delete them (or the whole `look` block) to get `hello`,
or set `"theme": "classic"` to keep the old look deliberately.
