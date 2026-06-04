import AppKit
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: RunOptions
    var window: NSWindow?
    var renderer: ZielRenderer?
    var director: Director?
    var config = ZielConfig()
    var displayManager: DisplayManager?
    private var demoTimer: Timer?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var gateway: GatewayClient?

    init(options: RunOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configURL = options.configPath.map { URL(fileURLWithPath: $0) } ?? ZielConfig.defaultURL
        config = ZielConfig.load(from: configURL)

        let director = Director(config: config)
        self.director = director

        let epoch = CACurrentMediaTime()
        let clock: () -> TimeInterval = { CACurrentMediaTime() - epoch }

        if options.demo {
            director.handle(.connectionUp, now: clock())
            startDemo(director: director, clock: clock)
        } else if options.debugState != nil {
            director.handle(.connectionUp, now: clock())
            applyDebugState(director: director, clock: clock)
        } else {
            let url = URL(string: config.gateway.url)
                ?? URL(string: GatewayConfig().url)!
            let identityURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ziel van Sebastian/device-identity.json")
            let identity = try? DeviceIdentity.loadOrCreate(at: identityURL)
            if identity == nil {
                NSLog("device identity unavailable at %@ — connecting without device pairing (gateway will clear scopes)",
                      identityURL.path)
            }
            let gateway = GatewayClient(
                url: url,
                token: config.gateway.token,
                identity: identity,
                onEvent: { [weak director] event in
                    DispatchQueue.main.async {
                        director?.handle(event, now: clock())
                    }
                }
            )
            self.gateway = gateway
            gateway.start()
        }

        let device = MTLCreateSystemDefaultDevice()!
        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.preferredFramesPerSecond = 60
        mtkView.colorPixelFormat = .bgra8Unorm

        let renderer = try! ZielRenderer(
            device: device,
            pixelFormat: mtkView.colorPixelFormat,
            fontName: config.look.fontName,
            shaderConfig: config.look.shader,
            clock: clock,
            sceneProvider: { [weak director] now in
                director?.tick(now: now)
                    ?? SceneState(phase: .offline(auth: false), phaseProgress: 1, timeInPhase: 0,
                                  word: nil, wordAge: 0, hint: nil, dozing: false,
                                  tint: ColorRGB(r: 0.1, g: 0.3, b: 0.1))
            }
        )
        self.renderer = renderer
        mtkView.delegate = renderer

        let window: NSWindow
        if options.window {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
            window.title = "Ziel van Sebastian"
            window.center()
        } else {
            window = NSWindow(contentRect: NSScreen.main?.frame ?? .zero,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.level = .mainMenu + 1
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            self.displayManager = DisplayManager(window: window, config: config.display)
        }
        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        // Place/front only after contentView is set, so the appliance never
        // shows an empty window. No-op on the --window path (displayManager nil).
        displayManager?.activate()

        watchConfig(at: configURL, renderer: renderer, director: director)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        gateway?.stop()
    }

    private func applyDebugState(director: Director, clock: () -> TimeInterval) {
        switch options.debugState {
        case "thinking":
            director.handle(.runStarted(run: "dbg", session: "dbg"), now: clock())
            director.handle(.toolStarted(run: "dbg", session: "dbg", tool: "read"), now: clock())
        case "offline":
            director.handle(.connectionDown(auth: false), now: clock())
        case "speaking":
            director.handle(.runStarted(run: "dbg", session: "dbg"), now: clock())
            director.handle(.textDelta(run: "dbg", session: "dbg",
                text: "The build finished. All 142 tests pass. Deploy went clean. Want me to tag the release? "), now: clock())
        default:
            if let s = options.debugState { fputs("warning: unknown --state '\(s)'\n", stderr) }
        }
    }

    private func startDemo(director: Director, clock: @escaping () -> TimeInterval) {
        var cursor = 0
        var loopStart = clock()
        // director lives for app lifetime — strong capture is intentional
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let now = clock()
            let t = now - loopStart
            while cursor < DemoScript.sequence.count && DemoScript.sequence[cursor].at <= t {
                director.handle(DemoScript.sequence[cursor].event, now: now)
                cursor += 1
            }
            if cursor >= DemoScript.sequence.count && t >= DemoScript.totalLength {
                cursor = 0
                loopStart = now
            }
        }
        timer.tolerance = 0.005
        demoTimer = timer
    }

    private func watchConfig(at url: URL, renderer: ZielRenderer, director: Director) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        // No file yet (first boot) — defaults in use. Note: if the config file
        // is DELETED later, the watcher dies and a recreated file won't be
        // seen until restart. Acceptable for the appliance; edit in place.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            // Keep last-good config when the file is mid-edit or invalid.
            if let data = try? Data(contentsOf: url),
               let fresh = try? ZielConfig.decode(data) {
                self?.config = fresh
                renderer.crt.shaderConfig = fresh.look.shader
                director.updatePacing(fresh.pacing)
            }
            // Editors often replace the file: re-arm the watcher.
            source.cancel()
            self?.watchConfig(at: url, renderer: renderer, director: director)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }
}
