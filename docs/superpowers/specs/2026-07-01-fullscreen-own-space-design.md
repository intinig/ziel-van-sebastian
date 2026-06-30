# Ziel van Sebastian — Fullscreen on Its Own Space

**Date:** 2026-07-01
**Status:** Approved

## What It Is

Run the appliance face as a native-fullscreen window on **its own macOS Space**, so a three-finger swipe moves between Ziel's desktop and a work desktop on the same (single) display. Swipe away to use the Mac for something else; swipe back to Ziel. Coupled with this, speech becomes **visibility-gated**: Ziel speaks only while its Space is the one you're looking at — quiet while you're away, and **live (never a replay) on return**.

## Why

The appliance path today creates a borderless, always-on-top overlay that joins *every* Space:

```swift
window = NSWindow(contentRect: NSScreen.main?.frame ?? .zero, styleMask: [.borderless], …)
window.level = .mainMenu + 1
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
NSApp.presentationOptions = [.hideDock, .hideMenuBar]
```

Because it joins all Spaces and floats above the menu bar, swiping can't escape it — the face follows you onto every desktop and covers other apps. That is the opposite of "give me a desktop to work on." Native fullscreen is the only public-API way to give a window a dedicated, swipeable Space.

## Approach

**Chosen: native fullscreen (`toggleFullScreen:`) with a `.fullScreenPrimary` window.** This is the macOS mechanism for an own-Space, three-finger-swipeable desktop. Robust, native; the menu bar/dock behave normally on the work Space.

Rejected alternatives:
- **Pin a borderless window to one managed Space.** No public API creates/assigns an arbitrary Space; needs private CoreGraphics (CGS) calls — fragile across OS updates.
- **Keep the overlay + a show/hide hotkey.** Not real desktops; you couldn't run other apps fullscreen "behind" it, and it doesn't match the swipe mental model.

Scope: single shared display; auto-fullscreen onto its own Space at launch (macOS switches to it). The `--window` dev path is unchanged.

## Design

Localized to `App/AppDelegate.swift` (window creation) and `App/DisplayManager.swift`, plus one small, testable addition to `Sources/Core/Director.swift`. No rendering changes.

### 1. Window & presentation

On the appliance path (`!options.window`):
- `styleMask = [.titled, .closable, .miniaturizable, .resizable]` — native fullscreen requires `.resizable`.
- Hide chrome so nothing shows pre-fullscreen: `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, insert `.fullSizeContentView`.
- `collectionBehavior = [.fullScreenPrimary]` — **drop** `.canJoinAllSpaces` and the `.mainMenu + 1` level.
- **Drop** `NSApp.presentationOptions = [.hideDock, .hideMenuBar]`. Native fullscreen auto-hides the menu bar/dock on Ziel's Space and leaves them normal on the work Space; forcing them app-wide would suppress them on the work Space while Ziel is frontmost.
- Keep `applicationShouldTerminateAfterLastWindowClosed == true`.

### 2. Launch sequence

Order matters for native fullscreen:
1. Build the window, set `contentView = mtkView`.
2. `DisplayManager` places it on the target screen (`setFrame(screen.frame)`, front, hide cursor) so fullscreen claims a Space on the target display.
3. `NSApp.activate(ignoringOtherApps: true)`.
4. `window.makeKeyAndOrderFront(nil)`.
5. `window.toggleFullScreen(nil)` → macOS animates into a new dedicated Space and switches to it.

Guarded to the appliance path; `--window` stays a normal resizable window with no toggle.

### 3. Display targeting & edge cases

`DisplayManager` keeps the display-sleep assertion and cursor hide. One change: on `didChangeScreenParameters`, if the window is already in fullscreen (`window.styleMask.contains(.fullScreen)`), do **not** `setFrame` (it fights the fullscreen Space); only re-place / re-enter fullscreen when not already fullscreen. On a single display this rarely fires but stays safe if the display drops and returns.

### 4. Visibility-gated speech (the skip)

Key fact: when Ziel is on a background Space it is **occluded**, so the render loop — which drives `SpeechCoordinator.pump()` — pauses. But the gateway keeps receiving text on the main queue, and already-queued audio would keep playing to an empty room, then a backlog would flush on return. To make returning *live* rather than a 30-second catch-up:

- Observe the window's occlusion state (`NSWindow.didChangeOcclusionStateNotification`; check `window.occlusionState.contains(.visible)`). On a fullscreen-own-Space window, "not visible" ⟺ "you swiped to another Space."
- **On swipe-away (becomes occluded):** call `speech.cancelAll()` — stop the current clip immediately and clear the coordinator's queues. Ziel goes quiet while you work.
- **On swipe-back (becomes visible):** call a new `Director.dropPendingSpeech(now:)` that clears the speech `outbox`/`speechQueue` accumulated while hidden and resets speak-state so the face doesn't wait on dropped sentences; then normal pumping resumes. Only text arriving *after* you return is spoken.

**Invariant:** Ziel speaks only what happens while its Space is visible. No catch-up — audio or RSVP.

The occlusion notification is wired in the App layer; the actual flush is two Core calls (`Director.dropPendingSpeech`, `SpeechCoordinator.cancelAll`) so the behavior is unit-testable.

## Testing

- `Director.dropPendingSpeech(now:)` — unit test (Core): enqueue sentences, drop, assert `outbox`/`speechQueue` empty and the face's run/phase state stays sane (no stuck "speaking" waiting on dropped ids).
- `SpeechCoordinator.cancelAll()` — already covered.
- Window creation, `toggleFullScreen`, occlusion wiring — AppKit, not unit-testable; validated live on the appliance:
  1. Boots into native fullscreen on its own Space.
  2. Three-finger swipe to a work Space → face hidden, normal menu bar/dock; Ziel is silent.
  3. Swipe back → Ziel visible; speech resumes from live (no replay of what was missed).
  4. Display-sleep prevention and hidden cursor still hold.
  5. `--window` dev mode unchanged.
- `CoreTests` stays green (148 + the new `dropPendingSpeech` test).

## Out of Scope / Future

- Multi-display behavior (current scope is a single shared display).
- Keeping speech playing on a background Space (the chosen behavior is the opposite — silence while away).
- Decoupling speech from the render loop so it advances while occluded — not needed given the skip-on-return invariant.
