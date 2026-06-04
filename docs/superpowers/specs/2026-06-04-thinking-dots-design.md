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

Three square pixel-art quads drawn with the flat pipeline (like the face), anchored
in the same box the dozing "z z Z" uses — NDC center **(0.55, 0.6)**, box
**0.18 × viewW** wide, **0.1 × viewH** tall (identical to the dozing `drawText`
parameters).

With B = box height (0.1 × viewH), per the approved mockup:

| | side | horizontal gap before | bottom lift vs dot 1 |
|---|---|---|---|
| dot 1 | 0.40 B | — | 0 |
| dot 2 | 0.60 B | 0.55 B | 0.125 B |
| dot 3 | 0.85 B | 0.55 B | 0.375 B |

Near-horizontal with a gentle rise to the right, sizes growing rightward (echoing
"z z Z"'s final capital). The 3-dot group's bounding box is centered on the anchor.
Dots use the phase tint (`scene.tint`) at alpha 1.0. In `hello` they cast the
theme's hard shadow exactly like the face and glyphs (`ScenePass` shadow path);
in `classic` there is no shadow, as everywhere else.

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

New `ScenePass` method (e.g. `drawThinkingDots(encoder:viewW:viewH:visible:tint:)`)
that computes the dot quads in NDC from the box constants above, draws the shadow
pass first when the theme has a shadow (reusing `shadowDeltaNDC`), then the
foreground — the same double-draw pattern as `drawFace`. `ZielRenderer.drawScene`'s
`.thinking` case calls it with `FaceAnimation.thinkingDotsVisible(at: now)` in
place of the removed sweep call.

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
