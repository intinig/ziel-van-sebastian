import Foundation

/// Decides when to (re)request native fullscreen until the window first gets there.
///
/// At login, macOS 27 can silently drop a `toggleFullScreen` issued seconds into the
/// session, leaving the face windowed under the menu bar. The app therefore verifies
/// each request after a delay and retries with backoff. Two rules keep it from
/// fighting the user or itself:
/// - once fullscreen has been reached it never requests again, so leaving fullscreen
///   on purpose sticks;
/// - it never requests while a transition is in flight, because `toggleFullScreen`
///   is a toggle and a late-arriving request would flip the window back out.
public struct FullscreenEntry: Equatable {
    public private(set) var attempts = 0
    public private(set) var isDone = false
    private var transitioning = false

    public init() {}

    /// Records a request; returns how long to wait before verifying it took effect.
    public mutating func requested() -> TimeInterval {
        attempts += 1
        return min(60, 3 * pow(2, Double(attempts - 1)))
    }

    public mutating func willEnter() { transitioning = true }
    public mutating func didEnter() { transitioning = false; isDone = true }
    public mutating func didFail() { transitioning = false }

    /// Whether to request fullscreen again, given the window's state at verification time.
    public func shouldRequest(isFullscreen: Bool) -> Bool {
        !isDone && !transitioning && !isFullscreen
    }
}
