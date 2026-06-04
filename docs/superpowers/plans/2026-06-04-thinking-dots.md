# Thinking Dots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the thinking-phase sweep band with three one-by-one animated square dots at the dozing "z z Z" anchor, in both themes.

**Architecture:** A new pure time function `FaceAnimation.thinkingDotsVisible` (Core, unit-tested) drives a new `ScenePass.drawThinkingDots` flat-quad method that reuses the existing shadow double-draw pattern. The sweep (`drawSweep`, `sweepY`, its test, and the renderer call) is deleted in the same commit that wires the dots in, so the tree stays green at every commit.

**Tech Stack:** Swift 5.10 (do NOT bump), Metal, XcodeGen (never edit `*.xcodeproj`), XCTest. `make test` is the source of truth; editor/SourceKit diagnostics are stale/noisy in this repo — ignore them.

**Spec:** `docs/superpowers/specs/2026-06-04-thinking-dots-design.md`

**Invariants:** `FaceGeometry.swift`, `Shaders.metal`, the dozing "z z Z", hint text, eyes-up gesture all untouched. `testLockedGeometry` stays green. No stored animation state — dots are pure functions of `now`.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Sources/Core/FaceAnimation.swift` | Modify | delete `sweepY`; add `thinkingDotsVisible` |
| `Sources/Rendering/ScenePass.swift` | Modify | delete `drawSweep`; add `drawThinkingDots`; fix file doc comment |
| `Sources/Rendering/ZielRenderer.swift` | Modify | `.thinking` case calls dots instead of sweep |
| `Tests/FaceAnimationTests.swift` | Modify | delete sweep test; add dots test |

---

### Task 1: `thinkingDotsVisible` (Core, additive)

Purely additive — `sweepY` stays for now (the renderer still calls it; it's removed in Task 2).

**Files:**
- Modify: `Sources/Core/FaceAnimation.swift` (insert after `sweepY`, which ends at line 28)
- Test: `Tests/FaceAnimationTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/FaceAnimationTests.swift` inside the `FaceAnimationTests` class, after `testSweepLoopsZeroToOne` (lines 31–35):

```swift
    func testThinkingDotsAppearOneByOne() {
        // 2s cycle, hard steps: blank, 1, 2, 3, blank.
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 0.0), 0)   // p = 0.0
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 0.4), 1)   // p = 0.2
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 1.0), 2)   // p = 0.5
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 1.5), 3)   // p = 0.75
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 1.8), 0)   // p = 0.9
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 2.4), 1)   // wraps: p = 0.2
        XCTAssertEqual(FaceAnimation.thinkingDotsVisible(at: 10.5, period: 1.0), 2) // p = 0.5
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | tail -10`
Expected: FAIL — compile error, `type 'FaceAnimation' has no member 'thinkingDotsVisible'`.

- [ ] **Step 3: Write the implementation**

In `Sources/Core/FaceAnimation.swift`, insert after the `sweepY` function (ends line 28):

```swift
    /// Thinking dots: how many of the three thought-bubble dots are visible.
    /// Hard steps (no easing) over a 2s cycle: blank, 1, 2, 3, blank.
    public static func thinkingDotsVisible(at t: TimeInterval, period: Double = 2.0) -> Int {
        let p = t.truncatingRemainder(dividingBy: period) / period
        switch p {
        case ..<0.15: return 0
        case ..<0.40: return 1
        case ..<0.65: return 2
        case ..<0.85: return 3
        default: return 0
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test 2>&1 | tail -10`
Expected: PASS — full suite including the new test and `testLockedGeometry`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/FaceAnimation.swift Tests/FaceAnimationTests.swift
git commit -m "feat: thinkingDotsVisible — one-by-one dot cycle, pure function of time"
```

---

### Task 2: Dots rendering; sweep removal

One atomic commit: the dots replace the sweep everywhere, so nothing dangles.

**Files:**
- Modify: `Sources/Rendering/ScenePass.swift` (file doc comment line 3; `drawSweep` at lines 135–148; insert `drawThinkingDots`)
- Modify: `Sources/Rendering/ZielRenderer.swift` (`.thinking` case in `drawScene`, lines ~120–124)
- Modify: `Sources/Core/FaceAnimation.swift` (delete `sweepY`, lines 25–28 incl. its doc comment)
- Modify: `Tests/FaceAnimationTests.swift` (delete `testSweepLoopsZeroToOne`, lines 31–35)

- [ ] **Step 1: Add `drawThinkingDots` to `Sources/Rendering/ScenePass.swift`**

Insert where `drawSweep` currently sits (you delete `drawSweep` in Step 2 — its body for reference ends at line 148):

```swift
    /// Thought-bubble trail at the dozing "z z Z" anchor (NDC 0.55, 0.6).
    /// Draws the first `visible` dots (0…3) left to right, sizes growing,
    /// near-horizontal with a gentle rise. Shadow pass first when themed.
    func drawThinkingDots(encoder: MTLRenderCommandEncoder,
                          viewW: Double, viewH: Double,
                          visible: Int, tint: ColorRGB) {
        guard visible > 0 else { return }
        let b = 0.1 * viewH                                  // zzz box height
        let sides = [0.40 * b, 0.60 * b, 0.85 * b]
        let gap = 0.55 * b
        let lifts = [0.0, 0.125 * b, 0.375 * b]              // bottom rise vs dot 1
        let groupW = sides.reduce(0, +) + 2 * gap
        let groupH = lifts[2] + sides[2]
        let anchorX = (1 + 0.55) / 2 * viewW                 // NDC 0.55 → screen px
        let anchorY = (1 - 0.6) / 2 * viewH                  // NDC 0.6 → screen px
        let bottomY = anchorY + groupH / 2

        var verts: [Float] = []
        var x = anchorX - groupW / 2
        for i in 0..<min(visible, 3) {
            let x0 = x, x1 = x + sides[i]
            let y1 = bottomY - lifts[i]                      // bottom (screen y down)
            let y0 = y1 - sides[i]                           // top
            let nx0 = Float(x0 / viewW * 2 - 1), nx1 = Float(x1 / viewW * 2 - 1)
            let ny0 = Float(1 - y0 / viewH * 2), ny1 = Float(1 - y1 / viewH * 2)
            verts += [nx0, ny0, nx1, ny0, nx0, ny1,
                      nx1, ny0, nx1, ny1, nx0, ny1]
            x = x1 + gap
        }

        encoder.setRenderPipelineState(flatPipeline)
        if let d = shadowDeltaNDC(viewW: viewW, viewH: viewH) {
            var shadowVerts = verts
            for i in stride(from: 0, to: shadowVerts.count, by: 2) {
                shadowVerts[i] += d.dx
                shadowVerts[i + 1] += d.dy
            }
            var shadowColor: [Float] = [Float(d.color.r), Float(d.color.g), Float(d.color.b), 1]
            encoder.setVertexBytes(shadowVerts, length: shadowVerts.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(&shadowColor, length: 16, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shadowVerts.count / 2)
        }
        var color: [Float] = [Float(tint.r), Float(tint.g), Float(tint.b), 1]
        encoder.setVertexBytes(verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 2)
    }
```

Why the loop is correct for partial visibility: dots appear left-to-right, so the
first `visible` dots are exactly the leftmost ones; `x` only ever advances over
drawn dots and stays aligned because layout is computed from the full group width.

- [ ] **Step 2: Delete `drawSweep` from `ScenePass.swift`**

Remove the whole method (lines 135–148) plus its doc comment line directly above
(`/// y in 0…1 from top; draws a soft horizontal band (thinking sweep).`):

```swift
    func drawSweep(encoder: MTLRenderCommandEncoder, y: Double,
                   tint: ColorRGB, intensity: Double) {
        let bandH: Float = 0.12
        let cy = Float(1 - y * 2)
        let verts: [Float] = [
            -1, cy - bandH, 1, cy - bandH, -1, cy + bandH,
            1, cy - bandH, 1, cy + bandH, -1, cy + bandH,
        ]
        var color: [Float] = [Float(tint.r), Float(tint.g), Float(tint.b), Float(intensity)]
        encoder.setRenderPipelineState(flatPipeline)
        encoder.setVertexBytes(verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
```

Also update the file doc comment at line 3 — `/// Renders SceneState content (face, sweep, word, hint) into the current` becomes:

```swift
/// Renders SceneState content (face, dots, word, hint) into the current
```

- [ ] **Step 3: Swap the call in `Sources/Rendering/ZielRenderer.swift`**

In `drawScene`'s `.thinking` case, replace:

```swift
            scenePass.drawSweep(encoder: encoder,
                                y: FaceAnimation.sweepY(at: now),
                                tint: scene.tint, intensity: 0.10)
```

with:

```swift
            scenePass.drawThinkingDots(encoder: encoder, viewW: viewW, viewH: viewH,
                                       visible: FaceAnimation.thinkingDotsVisible(at: now),
                                       tint: scene.tint)
```

(The comment about wander suppression and everything else in the case stays.)

- [ ] **Step 4: Delete `sweepY` from `Sources/Core/FaceAnimation.swift`**

Remove lines 25–28: the doc comment `/// Scanline sweep position 0…1 (top→bottom), period 2.8s.` and:

```swift
    public static func sweepY(at t: TimeInterval, period: Double = 2.8) -> Double {
        (t / period).truncatingRemainder(dividingBy: 1.0)
    }
```

- [ ] **Step 5: Delete `testSweepLoopsZeroToOne` from `Tests/FaceAnimationTests.swift`** (lines 31–35):

```swift
    func testSweepLoopsZeroToOne() {
        XCTAssertEqual(FaceAnimation.sweepY(at: 0), 0, accuracy: 0.01)
        XCTAssertEqual(FaceAnimation.sweepY(at: 1.4), 0.5, accuracy: 0.01)
        XCTAssertEqual(FaceAnimation.sweepY(at: 2.8), 0, accuracy: 0.01)
    }
```

- [ ] **Step 6: Verify no sweep references remain**

Run: `grep -rn -i "sweep" Sources/ Tests/ --include="*.swift"`
Expected: no matches.

- [ ] **Step 7: Test, build, launch-check**

```bash
make test 2>&1 | tail -5     # expected: PASS
make build 2>&1 | tail -3    # expected: BUILD SUCCEEDED
APP="./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian"
"$APP" --window --state thinking & P=$!; sleep 6; kill $P                      # hello
"$APP" --window --state thinking --theme classic & P=$!; sleep 6; kill $P     # classic
```

Expected: both stay alive, no errors. Visual confirmation (dots pop in one by one
top-right of the head, no band) is done by the controller with the human.

- [ ] **Step 8: Commit**

```bash
git add Sources/Rendering/ScenePass.swift Sources/Rendering/ZielRenderer.swift \
        Sources/Core/FaceAnimation.swift Tests/FaceAnimationTests.swift
git commit -m "feat: thinking dots replace sweep band — zzz-anchored, one-by-one"
```

---

## Post-implementation notes (not tasks)

- The thinking screenshot (`docs/screenshots/thinking.png`) capture — still pending
  from the hello-theme plan — should be taken AFTER this lands so it shows dots,
  not the sweep.
- Phosphor persistence gives vanishing dots a brief afterglow — expected, on-theme.
