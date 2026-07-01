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
    private var speech: SpeechCoordinator?
    private var occlusionObserver: NSObjectProtocol?
    private var spaceVisible = true

    init(options: RunOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configURL = options.configPath.map { URL(fileURLWithPath: $0) } ?? ZielConfig.defaultURL
        config = ZielConfig.load(from: configURL)

        let look: ResolvedLook
        do {
            look = try ResolvedLook.resolve(config.look, themeOverride: options.theme)
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }

        let director = Director(config: config, look: look)
        self.director = director

        let epoch = CACurrentMediaTime()
        let clock: () -> TimeInterval = { CACurrentMediaTime() - epoch }

        let voiceId = config.speech.voiceId
        let urlSafeVoiceId = !voiceId.isEmpty
            && voiceId.unicodeScalars.allSatisfy { CharacterSet.urlPathAllowed.contains($0) }
            && !voiceId.contains("/")
        if !config.speech.apiKey.isEmpty && urlSafeVoiceId {
            speech = SpeechCoordinator(director: director,
                                       synth: ElevenLabsTTS(config: config.speech),
                                       volume: config.speech.volume,
                                       now: clock)
        } else if config.speech.enabled {
            NSLog("speech.enabled is true but apiKey/voiceId missing or voiceId malformed — speech disabled (restart after fixing config)")
        }

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
                onEvent: { [weak director, weak self] event in
                    DispatchQueue.main.async {
                        if case .connectionDown = event { self?.speech?.cancelAll() }
                        director?.handle(event, now: clock())
                    }
                }
            )
            self.gateway = gateway
            gateway.start()

            // TEMPORARY (Task 4 dev trigger, removed in Phase 3 when the real
            // voice coordinator lands): set ZIEL_VOICE_DEV_PROMPT to a non-empty
            // string to inject it as a one-shot prompt a few seconds after
            // connecting, so the input→OpenClaw→output loop can be exercised on
            // the appliance without a microphone.
            if let devPrompt = ProcessInfo.processInfo.environment["ZIEL_VOICE_DEV_PROMPT"],
               !devPrompt.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak gateway] in
                    NSLog("ZIEL_VOICE_DEV_PROMPT: sending dev prompt %@", devPrompt)
                    gateway?.sendPrompt(devPrompt)
                }
            }
        }

        let device = MTLCreateSystemDefaultDevice()!
        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.preferredFramesPerSecond = 60
        mtkView.colorPixelFormat = .bgra8Unorm

        let renderer = try! ZielRenderer(
            device: device,
            pixelFormat: mtkView.colorPixelFormat,
            look: look,
            clock: clock,
            sceneProvider: { [weak director, weak self] now in
                let scene = director?.tick(now: now)
                    ?? SceneState(phase: .offline(auth: false), phaseProgress: 1, timeInPhase: 0,
                                  word: nil, wordAge: 0, hint: nil, dozing: false,
                                  tint: ColorRGB(r: 0.1, g: 0.3, b: 0.1), level: 0)
                // MTKView keeps rendering while Ziel is on a background Space, so
                // gate the pump on visibility — otherwise text that arrives while
                // hidden gets spoken. spaceVisible is false between swipe-away and
                // swipe-back; it stays true on the --window path (no observer).
                if self?.spaceVisible ?? true { self?.speech?.pump() }
                return scene
            }
        )
        self.renderer = renderer
        renderer.crt.waveform = config.waveform
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

        if !options.window {
            // Speak only while Ziel's Space is the one on screen. MTKView keeps
            // rendering on a background Space, so the sceneProvider gates pump() on
            // spaceVisible (above); here we handle the edges — on swipe-away go
            // quiet and clear queued audio, on swipe-back drop whatever text accrued
            // while hidden and resume live. occlusionState loses .visible exactly
            // when you swipe to another Space (this window is alone on its own Space).
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self, clock] _ in
                guard let self, let window = self.window else { return }
                let visible = window.occlusionState.contains(.visible)
                guard visible != self.spaceVisible else { return }
                self.spaceVisible = visible
                if visible {
                    // Re-arm the one-shot cursor hide: moving the mouse on the work
                    // desktop consumed DisplayManager's, so the pointer would linger
                    // over the face on return until the next place().
                    NSCursor.setHiddenUntilMouseMoves(true)
                    self.director?.dropPendingSpeech(now: clock())   // skip the backlog, resume live
                } else {
                    self.speech?.cancelAll()                          // go quiet now, clear queues
                }
            }
        }

        watchConfig(at: configURL, renderer: renderer, director: director)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        gateway?.stop()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
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
        case "idle":
            break  // connectionUp (sent by the caller) already lands on idle
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
               let fresh = try? ZielConfig.decode(data),
               let freshLook = try? ResolvedLook.resolve(fresh.look, themeOverride: self?.options.theme) {
                self?.config = fresh
                renderer.crt.shaderConfig = freshLook.shader
                renderer.crt.waveform = fresh.waveform
                director.updatePacing(fresh.pacing)
                director.setSpeechEnabled(fresh.speech.enabled)
                self?.speech?.volume = fresh.speech.volume
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
