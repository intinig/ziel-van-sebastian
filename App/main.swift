import AppKit
import ServiceManagement

struct RunOptions {
    var window = false
    var demo = false
    var configPath: String?
    var installLoginItem = false
    var debugState: String?

    static func parse(_ args: [String]) -> RunOptions {
        var o = RunOptions()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--window": o.window = true
            case "--demo": o.demo = true
            case "--install-login-item": o.installLoginItem = true
            case "--config":
                i += 1
                if i < args.count {
                    o.configPath = args[i]
                } else {
                    fputs("error: --config requires a path argument\n", stderr)
                    exit(1)
                }
            case "--state":
                i += 1
                if i < args.count { o.debugState = args[i] }
            case "--version":
                print("ziel-van-sebastian 0.1.0")
                exit(0)
            default: break
            }
            i += 1
        }
        return o
    }
}

let options = RunOptions.parse(CommandLine.arguments)

if options.installLoginItem {
    do {
        try SMAppService.mainApp.register()
        print("registered as login item")
        exit(0)
    } catch {
        print("login item registration failed: \(error)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)

// Minimal main menu so Cmd-Q works (the app has no other chrome).
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "Quit Ziel van Sebastian",
                           action: #selector(NSApplication.terminate(_:)),
                           keyEquivalent: "q"))
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
