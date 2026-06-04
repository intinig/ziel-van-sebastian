import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: RunOptions

    init(options: RunOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Window + renderer wiring arrives in Task 11.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
