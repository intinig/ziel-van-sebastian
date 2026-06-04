# Thinking Dots — Design

**Date:** 2026-06-04
**Branch:** `new-graphics`
**Status:** approved in brainstorm (visual companion, "take 4" layout + one-by-one animation)

## Goal

Replace the thinking-phase sweep band (full-width moving refresh band) with three
animated square dots — a thought-bubble trail at the exact position of the dozing
"z z Z" — in **both themes**. The sweep reads poorly on the small appliance screen.

## Removal

Delete, with no config knob or fallback:

- `ScenePass.drawSweep` (`Sources/Rendering/ScenePass.swift`)
- `FaceAnimation.sweepY` (`Sources/Core/FaceAnimation.swift`)
- `testSweepLoopsZeroToOne` (`Tests/FaceAnimationTests.swift`)
- The `drawSweep`/`sweepY` call in `ZielRenderer.drawScene`'s `.thinking` case

## Dots — geometry

**The dots are rendered through the exact same path as the dozing "z z Z":** the
renderer's `drawText` with the identical parameters — center NDC **(0.55, 0.6)**,
`maxWFrac` **0.18**, `maxHFrac` **0.1**, phase tint, alpha 1.0. No custom quad
geometry, no hand-tuned offsets: whatever box, baseline, and scale the zzz gets,
the dots get.

The text for N visible dots is a five-cell monospace string (Menlo-Bold is
monospaced, and `". . ."` is five cells exactly like `"z z Z"`):

| visible | string |
|---|---|
| 1 | `".    "` (dot + 4 spaces) |
| 2 | `". .  "` (dot, space, dot, 2 spaces) |
| 3 | `". . ."` |

All three strings have identical typographic width (monospace) and identical
texture height (the rasterizer always uses full line height), so the fitted quad
is the same for every count — dots appear in place, left to right, without the
group shifting or rescaling. Dots sit on the same baseline as the zzz glyphs —
flat, not diagonal — and inherit the theme shadow through the existing glyph
shadow path (`hello`: hard shadow; `classic`: none).

Caveat: a non-monospaced `fontName` override in config would make the padded
strings drift slightly; the dozing zzz spacing makes the same assumption, so this
is accepted.

## Animation — pure function of time

New `FaceAnimation.thinkingDotsVisible(at t: TimeInterval, period: Double = 2.0) -> Int`
returning how many dots (0…3) are visible. Hard steps, no easing (1984-style),
2-second cycle. With p = (t mod period) / period:

| phase p | visible |
|---|---|
| [0, 0.15) | 0 |
| [0.15, 0.40) | 1 |
| [0.40, 0.65) | 2 |
| [0.65, 0.85) | 3 |
| [0.85, 1) | 0 |

The renderer draws the first N dots — no stored animation state, consistent with
the FaceAnimation invariant. Eyes-up gesture, blink/breathe, and the hint text in
the thinking phase are unchanged. The dozing "z z Z" itself is unchanged.

## Rendering

No new ScenePass method. `ZielRenderer.drawScene`'s `.thinking` case replaces the
removed sweep call with a `drawText` call (the zzz parameters above), selecting
the string by `FaceAnimation.thinkingDotsVisible(at: now)` and skipping the call
when the count is 0. Glyph textures are cached per string by `GlyphRasterizer`
(3 cache entries).

## Testing

- `Tests/FaceAnimationTests.swift`: remove the sweep test; add a test pinning
  `thinkingDotsVisible` at the phase boundaries (0, 1, 2, 3, 0 across one period,
  plus wrap-around at t > period).
- Rendering verified visually via `make run` (both themes), per project convention.
- `testLockedGeometry` untouched.

## Non-goals

- No config keys for dot geometry or timing.
- No changes to the dozing "z z Z", hint text, eyes-up gesture, or any other phase.
- No theme-specific dot behavior (only the shadow differs, via the existing path).
