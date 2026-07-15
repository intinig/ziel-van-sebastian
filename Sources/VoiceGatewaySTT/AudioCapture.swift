import Foundation
import AVFoundation
import CoreAudio

/// Mic capture → 16 kHz mono Float32, chunked into 512-sample VAD frames.
/// Device selection is by name substring (matches `voice.inputDevice`); empty → system default.
public final class AudioCapture {
    private let engine = AVAudioEngine()
    private let onFrame: ([Float]) -> Void
    private let deviceName: String?
    private let queue = DispatchQueue(label: "voice-audio")
    private var residue: [Float] = []
    private var stopped = false
    private var restarting = false
    private var configChangeObserver: NSObjectProtocol?

    public init(deviceName: String?, onFrame: @escaping ([Float]) -> Void) {
        self.deviceName = (deviceName?.isEmpty ?? true) ? nil : deviceName
        self.onFrame = onFrame
    }

    public func start() throws {
        try requestMicAccessSync()
        try configureAndStart()
        // A running AVAudioEngine's input can die silently when the device
        // reconfigures (sample-rate change, USB unplug/replug, etc.) — frames
        // keep flowing as silence with no error and VAD goes deaf. Tear down
        // and restart the capture path when the system reports a
        // configuration change.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Fires on an arbitrary thread; hop onto `queue` to serialize
            // with `chunk(_:)` and with `stop()`.
            self?.queue.async { self?.beginRestart() }
        }
    }

    public func stop() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        queue.sync {
            stopped = true
            restarting = false
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            residue = []
        }
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Selects the pinned device (if any), builds a converter for the
    /// engine's *current* native format, installs the tap, and starts the
    /// engine. Used both for the initial `start()` and for restarting after a
    /// configuration-change notification — always rebuilding the format and
    /// converter fresh so a restart picks up the device's new native format.
    private func configureAndStart() throws {
        if let name = deviceName {
            guard let dev = Self.findInputDevice(named: name) else {
                throw NSError(domain: "AudioCapture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "no input device matching \"\(name)\""])
            }
            var deviceID = dev
            guard let unit = engine.inputNode.audioUnit else {
                throw NSError(domain: "AudioCapture", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "input node has no audio unit"])
            }
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &deviceID,
                                           UInt32(MemoryLayout<AudioDeviceID>.size))
            guard err == noErr else {
                throw NSError(domain: "AudioCapture", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "failed to select device (\(err))"])
            }
        }
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                   channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: native, to: target) else {
            throw NSError(domain: "AudioCapture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "no converter \(native) → 16k mono"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / native.sampleRate + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard let ch = out.floatChannelData, out.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            self.queue.async { self.chunk(samples) }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)   // leave no tap behind so a retry of start() is safe
            throw error
        }
    }

    // MARK: - Configuration-change recovery

    /// Entry point for a configuration-change restart. Must run on `queue`.
    private func beginRestart() {
        guard !stopped, !restarting else { return }
        restarting = true
        residue = []   // stale halves of frames from the old format must not prepend the new stream
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        attemptRestart(attempt: 1)
    }

    /// Retries `configureAndStart()` every 2 s until it succeeds. Must run on `queue`.
    private func attemptRestart(attempt: Int) {
        guard !stopped else { restarting = false; return }
        do {
            try configureAndStart()
            restarting = false
            log("engine restarted after configuration change (attempt \(attempt))")
        } catch {
            log("engine restart attempt \(attempt) failed: \(error.localizedDescription); retrying in 2s")
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.attemptRestart(attempt: attempt + 1)
            }
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("[AudioCapture] \(s)\n".utf8))
    }

    private func chunk(_ samples: [Float]) {
        residue += samples
        while residue.count >= 512 {
            onFrame(Array(residue.prefix(512)))
            residue.removeFirst(512)
        }
    }

    private func requestMicAccessSync() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { granted = $0; sem.signal() }
            sem.wait()
            if granted { return }
            fallthrough
        default:
            throw NSError(domain: "AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "microphone access denied — grant it in System Settings → Privacy & Security → Microphone"])
        }
    }

    /// Case-insensitive substring match over input-capable CoreAudio devices.
    static func findInputDevice(named name: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return nil }
        for id in ids {
            var inputAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                       mScope: kAudioDevicePropertyScopeInput,
                                                       mElement: kAudioObjectPropertyElementMain)
            var cfgSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &inputAddr, 0, nil, &cfgSize) == noErr, cfgSize > 0 else { continue }
            // `cfgSize` is a byte count; allocate exactly that many bytes (not
            // `cfgSize` *elements* of AudioBufferList, which would over-allocate)
            // and bind the raw memory to the variable-length AudioBufferList type.
            let rawBuf = UnsafeMutableRawPointer.allocate(byteCount: Int(cfgSize),
                                                          alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawBuf.deallocate() }
            let buf = rawBuf.bindMemory(to: AudioBufferList.self, capacity: 1)
            guard AudioObjectGetPropertyData(id, &inputAddr, 0, nil, &cfgSize, buf) == noErr,
                  UnsafeMutableAudioBufferListPointer(buf).reduce(0, { $0 + Int($1.mNumberChannels) }) > 0
            else { continue }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var cfName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            // CoreAudio's Copy rule hands back a +1-retained CFString here; Swift's
            // ARC balances it with a release when `cfName` goes out of scope below —
            // fragile if this is ever refactored to hold the pointer/value longer.
            guard withUnsafeMutablePointer(to: &cfName, { ptr in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
            }) == noErr else { continue }
            if (cfName as String).localizedCaseInsensitiveContains(name) { return id }
        }
        return nil
    }
}
