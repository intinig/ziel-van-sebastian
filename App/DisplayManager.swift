import AppKit
import IOKit.pwr_mgt

/// Finds the Wokyis panel, owns the fullscreen window placement, hides the
/// cursor, blocks display sleep, and survives display reconfiguration.
final class DisplayManager {
    private let config: DisplayConfig
    private let window: NSWindow
    private var sleepAssertion: IOPMAssertionID = 0
    private var observer: NSObjectProtocol?

    init(window: NSWindow, config: DisplayConfig) {
        self.window = window
        self.config = config
    }

    func activate() {
        place()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.place()
        }
        if config.preventDisplaySleep {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Ziel van Sebastian appliance display" as CFString,
                &sleepAssertion)
            if result != kIOReturnSuccess {
                fputs("warning: display-sleep assertion failed (\(result))\n", stderr)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
    }

    /// Preference: name match → smallest display → hide and wait.
    func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let needles = config.preferredNameContains.map { $0.lowercased() }
        if let named = screens.first(where: { screen in
            let name = screen.localizedName.lowercased()
            return needles.contains { name.contains($0) }
        }) {
            return named
        }
        return screens.min { a, b in
            a.frame.width * a.frame.height < b.frame.width * b.frame.height
        }
    }

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
}
