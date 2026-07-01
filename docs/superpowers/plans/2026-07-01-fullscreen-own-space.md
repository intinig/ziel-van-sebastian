# Fullscreen Own-Space Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the appliance face as a native-fullscreen window on its own macOS Space (three-finger swipe to a work desktop and back), and make speech play only while Ziel's Space is visible — silent while away, live on return, no catch-up.

**Architecture:** Replace the appliance window's all-Spaces top-most overlay with a `.fullScreenPrimary` window driven into native fullscreen at launch. Observe the window's occlusion state: on swipe-away stop + clear speech (`SpeechCoordinator.cancelAll()`); on swipe-back drop the speech backlog accrued while the render loop was paused (`Director.dropPendingSpeech(now:)`) so playback resumes live.

**Tech Stack:** Swift 5.10, AppKit (`NSWindow`, native fullscreen, occlusion notifications), Metal (`MTKView`, unchanged), XCTest (`CoreTests`). Spec: `docs/superpowers/specs/2026-07-01-fullscreen-own-space-design.md`.

## Global Constraints

- Swift language mode **5.10** — do not bump.
- Scope is a **single shared display**; no multi-display logic.
- The `--window` dev path (`options.window == true`) must stay **unchanged** (normal resizable window, no fullscreen toggle).
- Core code never reads a clock — all time is injected via `now:` parameters (`Director.dropPendingSpeech(now:)` follows this).
- `*.xcodeproj` is generated — edit `project.yml`, never the project file. (No project.yml change is needed for this plan.)
- `make test` (CoreTests) must stay green.

**Verification commands used below:**
- Single Core test: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/<Suite>/<test> test`
- Full suite: `make test`
- Compile the app (AppKit tasks): `make build`

**Manual-validation prerequisite (Tasks 2–3):** live validation runs on the appliance. `scripts/deploy.sh` currently targets the stale host `vosne-romanee`; the appliance is now `vosne-romanee-1`. Update that host (two `ssh`/`rsync` references) before deploying, or deploy by hand. This is infra, not part of a feature commit.

## File Structure

- `Sources/Core/Director.swift` — add `dropPendingSpeech(now:)` (Task 1). Only addition; no existing logic changes.
- `Tests/DirectorSpeechTests.swift` — add tests for `dropPendingSpeech` (Task 1).
- `App/AppDelegate.swift` — appliance window becomes fullscreen-capable + launch toggle (Task 2); occlusion observer wiring (Task 3).
- `App/DisplayManager.swift` — don't re-`setFrame` while already fullscreen (Task 2).

---

### Task 1: `Director.dropPendingSpeech(now:)` — skip backlog accrued while hidden

**Files:**
- Modify: `Sources/Core/Director.swift` (add one public method in the `// MARK: - Speech state` API region, e.g. right after `speechFinished(id:now:)` ~line 102)
- Test: `Tests/DirectorSpeechTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `public func dropPendingSpeech(now: TimeInterval)` — clears the speech `outbox`, `speechQueue`, the `SentenceChunker`, the `WordPacer`, and the current display word, while leaving `runs`/`focusedRun`/`phase` intact so `advance(now:)` resumes live. Used by Task 3.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/DirectorSpeechTests.swift` (before the final closing brace). `makeSpeechDirector()` already exists in this file.

```swift
    func testDropPendingSpeechSkipsBacklogButResumesLive() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        // Backlog queued while Ziel sat on a hidden Space (the render loop, and
        // thus the speech pump, was paused — but gateway text kept arriving):
        d.handle(.textDelta(run: "r1", session: "main", text: "One. Two. Three. "), now: 1)

        d.dropPendingSpeech(now: 5)
        XCTAssertEqual(d.takeSpeechRequests(), [], "missed backlog is skipped, not replayed")

        // Text arriving after returning is spoken live:
        d.handle(.textDelta(run: "r1", session: "main", text: "Four. "), now: 6)
        XCTAssertEqual(d.takeSpeechRequests().map(\.text), ["Four."], "live text after return is spoken")
    }

    func testDropPendingSpeechDoesNotStrandTheFace() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "One. Two. "), now: 1)
        d.handle(.runEnded(run: "r1", session: "main"), now: 1.1)
        _ = d.takeSpeechRequests()
        // Swiped away, then back after the run already ended: nothing left to say.
        d.dropPendingSpeech(now: 5)
        XCTAssertEqual(d.tick(now: 5.1).phase, .settling)   // winds down, not stuck "busy"
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/DirectorSpeechTests/testDropPendingSpeechSkipsBacklogButResumesLive test`

Expected: FAIL to compile — `value of type 'Director' has no member 'dropPendingSpeech'`.

- [ ] **Step 3: Implement `dropPendingSpeech`**

Add to `Sources/Core/Director.swift`, in the speech API region (e.g. immediately after `speechFinished(id:now:)`):

```swift
    /// Returning from a hidden Space (the render loop — and the speech pump —
    /// was paused while Ziel was on another desktop): discard speech that
    /// queued while we weren't watching so it isn't replayed, and clear the
    /// display word. `runs`/`focusedRun`/`phase` are left intact, so the next
    /// `advance(now:)` resumes live — speaking new text or winding down.
    public func dropPendingSpeech(now: TimeInterval) {
        speechQueue.removeAll()
        outbox.removeAll()
        chunker = SentenceChunker()
        pacer.reset()
        currentWord = nil
        wordFromPacer = true
        lastActivity = now
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/DirectorSpeechTests test`

Expected: PASS — all `DirectorSpeechTests` green (the two new tests included).

- [ ] **Step 5: Run the full suite**

Run: `make test`
Expected: `** TEST SUCCEEDED **`, `0 failures`, with the two new `DirectorSpeechTests` listed among them. (This branch's baseline is 147 → 149; the crash-fix branch's extra test is not on this branch.)

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Director.swift Tests/DirectorSpeechTests.swift
git commit -m "feat: Director.dropPendingSpeech — skip speech backlog accrued while hidden

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Appliance window runs in its own fullscreen Space

**Files:**
- Modify: `App/AppDelegate.swift` — the `else` (appliance) branch of the `let window: NSWindow` block in `applicationDidFinishLaunching`, and the front/activate sequence right after it.
- Modify: `App/DisplayManager.swift` — `place()`.

**Interfaces:**
- Consumes: nothing new.
- Produces: appliance launches into native fullscreen on its own Space. No new symbols.

- [ ] **Step 1: Replace the appliance window creation**

In `App/AppDelegate.swift`, the current appliance branch reads:

```swift
        } else {
            window = NSWindow(contentRect: NSScreen.main?.frame ?? .zero,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.level = .mainMenu + 1
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            self.displayManager = DisplayManager(window: window, config: config.display)
        }
```

Replace that `else` block with:

```swift
        } else {
            window = NSWindow(contentRect: NSScreen.main?.frame ?? .zero,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            // Hidden chrome so nothing shows if the window is ever seen pre-fullscreen;
            // .fullScreenPrimary lets it own a Space you can three-finger-swipe to.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.collectionBehavior = [.fullScreenPrimary]
            self.displayManager = DisplayManager(window: window, config: config.display)
        }
```

(Removes `.borderless`, the `.mainMenu + 1` level, `.canJoinAllSpaces`, and the app-wide `presentationOptions` — native fullscreen handles menu-bar/dock hiding per Space.)

- [ ] **Step 2: Enter fullscreen after the window is placed**

The lines immediately after the `if/else` block currently read:

```swift
        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        // Place/front only after contentView is set, so the appliance never
        // shows an empty window. No-op on the --window path (displayManager nil).
        displayManager?.activate()
```

Add the fullscreen toggle right after `displayManager?.activate()`:

```swift
        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        // Place/front only after contentView is set, so the appliance never
        // shows an empty window. No-op on the --window path (displayManager nil).
        displayManager?.activate()
        if !options.window {
            // Native fullscreen → a dedicated Space macOS switches to; swipe away
            // for a work desktop and back. Placed on the target screen first.
            window.toggleFullScreen(nil)
        }
```

- [ ] **Step 3: Guard `DisplayManager.place()` against fighting fullscreen**

In `App/DisplayManager.swift`, `place()` currently reads:

```swift
    private func place() {
        guard let screen = targetScreen() else {
            window.orderOut(nil)   // no displays at all; wait for the next change
            return
        }
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        // Idempotent — NSCursor.hide() is refcounted and would accumulate on
        // every display reconfiguration, so we deliberately don't call it.
        NSCursor.setHiddenUntilMouseMoves(true)
    }
```

Replace it with:

```swift
    private func place() {
        guard let screen = targetScreen() else {
            window.orderOut(nil)   // no displays at all; wait for the next change
            return
        }
        // While in native fullscreen the window owns its Space; re-setting the
        // frame fights macOS. Only position it when not (yet) fullscreen — the
        // initial place() runs before toggleFullScreen, so launch still lands on
        // the target display.
        if !window.styleMask.contains(.fullScreen) {
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
        }
        // Idempotent — NSCursor.hide() is refcounted and would accumulate on
        // every display reconfiguration, so we deliberately don't call it.
        NSCursor.setHiddenUntilMouseMoves(true)
    }
```

- [ ] **Step 4: Build**

Run: `make build`
Expected: `** BUILD SUCCEEDED **` for both `ZielVanSebastian` and `mock-gateway`.

- [ ] **Step 5: Manual validation on the appliance**

Deploy (after the deploy.sh host fix noted above) and confirm:
1. Ziel boots straight into native fullscreen on its own Space (macOS switches to it).
2. Three-finger swipe left/right moves to an adjacent (work) desktop — the face is **not** there; the menu bar/dock are normal.
3. Swipe back → Ziel.
4. Cursor stays hidden; display does not sleep.
5. `make run` (or `--window`) still shows a normal 960×540 resizable window — unchanged.

- [ ] **Step 6: Commit**

```bash
git add App/AppDelegate.swift App/DisplayManager.swift
git commit -m "feat: appliance face runs in its own native-fullscreen Space

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Gate speech on Space visibility — silent away, live on return

**Files:**
- Modify: `App/AppDelegate.swift` — add two stored properties, an occlusion observer set up in `applicationDidFinishLaunching` (appliance path), and observer removal in `applicationWillTerminate`.

**Interfaces:**
- Consumes: `Director.dropPendingSpeech(now:)` (Task 1); `SpeechCoordinator.cancelAll()` (existing); the appliance fullscreen window (Task 2, so "not visible" ⟺ "on another Space").
- Produces: nothing other tasks rely on.

- [ ] **Step 1: Add the observer state properties**

In `App/AppDelegate.swift`, alongside the other private stored properties (near `private var gateway: GatewayClient?` / `private var speech: SpeechCoordinator?`), add:

```swift
    private var occlusionObserver: NSObjectProtocol?
    private var spaceVisible = true
```

- [ ] **Step 2: Wire the occlusion observer (appliance path only)**

In `applicationDidFinishLaunching`, after the `if !options.window { window.toggleFullScreen(nil) }` added in Task 2 (and before `watchConfig(...)`), add. Note `clock` and `director` are in scope here; capture `clock` directly.

```swift
        if !options.window {
            // Speak only while Ziel's Space is the one on screen. While it's on a
            // background Space the render loop (and the speech pump) is paused, but
            // gateway text keeps arriving — so on swipe-away we go quiet and clear
            // queued audio, and on swipe-back we drop whatever accrued while hidden
            // and resume live. occlusionState loses .visible exactly when you swipe
            // to another Space (this window is alone on its own fullscreen Space).
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self, clock] _ in
                guard let self, let window = self.window else { return }
                let visible = window.occlusionState.contains(.visible)
                guard visible != self.spaceVisible else { return }
                self.spaceVisible = visible
                if visible {
                    self.director?.dropPendingSpeech(now: clock())   // skip the backlog, resume live
                } else {
                    self.speech?.cancelAll()                          // go quiet now, clear queues
                }
            }
        }
```

- [ ] **Step 3: Remove the observer on terminate**

In `App/AppDelegate.swift`, `applicationWillTerminate` currently reads:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        gateway?.stop()
    }
```

Replace with:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        gateway?.stop()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }
```

- [ ] **Step 4: Build**

Run: `make build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual validation on the appliance**

With speech enabled and a source of replies (e.g. trigger a cron reply), confirm:
1. While Ziel is visible, it speaks normally.
2. Swipe to a work Space mid-reply → audio stops immediately; Ziel is silent while you work.
3. Let several replies arrive while away (30 s+), then swipe back → Ziel does **not** replay the backlog; it picks up live from current text (or is idle if the agent finished).
4. `make test` still green (no Core regressions): `make test` → `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add App/AppDelegate.swift
git commit -m "feat: gate speech on Space visibility — silent away, live on return

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Window & presentation (spec §1) → Task 2 Step 1. ✓
- Launch sequence (spec §2) → Task 2 Step 2. ✓
- Display targeting + fullscreen guard (spec §3) → Task 2 Step 3. ✓
- Visibility-gated speech / skip (spec §4) → Task 1 (`dropPendingSpeech`) + Task 3 (occlusion wiring, `cancelAll` on hide). ✓
- Testing (spec §5): `dropPendingSpeech` unit-tested (Task 1); window/occlusion validated live (Tasks 2–3 Step 5). ✓
- `--window` unchanged: Task 2 keeps the `if options.window` branch as-is; fullscreen toggle and observer are both guarded by `!options.window`. ✓

**Placeholder scan:** none — every code step shows complete code; manual-validation steps are explicit checklists (AppKit window/Space/occlusion behavior is not unit-testable, called out in the spec).

**Type consistency:** `dropPendingSpeech(now:)` defined in Task 1 is called with `clock()` (`() -> TimeInterval`) in Task 3. `SpeechCoordinator.cancelAll()` and `Director.takeSpeechRequests()` match existing signatures. `NSWindow.didChangeOcclusionStateNotification` / `occlusionState.contains(.visible)` are AppKit API. `collectionBehavior = [.fullScreenPrimary]`, `toggleFullScreen(_:)`, `styleMask.contains(.fullScreen)` are AppKit API.
