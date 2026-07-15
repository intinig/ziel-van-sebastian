import AVFoundation
import CoreAudio
import Foundation

/// Real synthesizer: ElevenLabs with-timestamps over URLSession, playback via
/// AVAudioEngine. Kept thin — request building and response parsing are static
/// and unit-tested; the network/audio glue is verified manually (`make run`).
public final class ElevenLabsTTS: SpeechSynthesizing {
    private static let sampleRate = 24_000.0

    private let config: SpeechConfig
    private let session: URLSession
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineReady = false
    private var configObserver: NSObjectProtocol?
    /// Device actually applied via AudioUnitSetProperty; nil means "not yet
    /// applied" (default device, or a pin still pending discovery). Guards
    /// against re-invoking AudioUnitSetProperty on every play() call — see
    /// the engine-reconfiguration risk class noted below. Reset whenever the
    /// graph is rebuilt so a real hardware/device change re-applies the pin.
    private var appliedDeviceID: AudioDeviceID?

    /// Non-empty pins TTS output to a named device (e.g. the PowerConf) so mic
    /// and speaker share one unit for hardware AEC. Set live from voice.outputDevice.
    public var outputDeviceName: String = ""

    public init(config: SpeechConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        // The engine stops itself when the audio route/hardware changes (dock or
        // display sleep, output device swap). If we don't rebuild the graph the
        // next play() restarts a torn-down engine and the in-flight buffer's
        // completion is lost. Tear down here so the next play() re-attaches,
        // reconnects at the new hardware format, and restarts cleanly.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            NSLog("speech: audio engine configuration changed — rebuilding graph")
            self.engine.stop()
            if self.engineReady {
                self.engine.disconnectNodeOutput(self.player)
                self.engine.detach(self.player)
                self.engineReady = false
                // The device pin may not survive a hardware reconfiguration (this
                // is exactly the kind of route change — dock/output swap — that
                // can invalidate it), so forget it and let the next play() re-apply.
                self.appliedDeviceID = nil
            }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    enum TTSError: Error {
        case httpStatus(Int)
        case malformedResponse
    }

    private struct ResponseBody: Decodable {
        let audioBase64: String
        let alignment: ElevenLabsAlignment?
        enum CodingKeys: String, CodingKey {
            case audioBase64 = "audio_base64"
            case alignment
        }
    }

    static func makeRequest(text: String, previousRequestIDs: [String], config: SpeechConfig) -> URLRequest {
        var comps = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(config.voiceId)/with-timestamps")!
        comps.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "text": text,
            "model_id": config.modelId,
            "voice_settings": ["speed": config.speed],
        ]
        if let lang = config.languageCode { body["language_code"] = lang }
        if !previousRequestIDs.isEmpty { body["previous_request_ids"] = previousRequestIDs }
        req.httpBody = try! JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func parseResponse(_ data: Data, requestID: String?) throws -> SpokenAudio {
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let pcm = Data(base64Encoded: body.audioBase64), !pcm.isEmpty,
              let alignment = body.alignment
        else { throw TTSError.malformedResponse }
        let words = AlignmentMapper.words(from: alignment)
        guard !words.isEmpty else { throw TTSError.malformedResponse }
        let envelope = AmplitudeEnvelope.from(pcm: pcm, sampleRate: sampleRate, rate: 60)
        return SpokenAudio(requestID: requestID, words: words, pcm: pcm, sampleRate: sampleRate,
                           envelope: envelope, envelopeRate: 60)
    }

    public func fetch(_ request: SpeechRequest, previousRequestIDs: [String],
                      completion: @escaping (Result<SpokenAudio, Error>) -> Void) {
        let urlReq = Self.makeRequest(text: request.text, previousRequestIDs: previousRequestIDs, config: config)
        let task = session.dataTask(with: urlReq) { data, response, error in
            func finish(_ r: Result<SpokenAudio, Error>) {
                DispatchQueue.main.async { completion(r) }
            }
            if let error {
                finish(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(.failure(TTSError.malformedResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                NSLog("speech: TTS request failed with HTTP %d", http.statusCode)
                finish(.failure(TTSError.httpStatus(http.statusCode)))
                return
            }
            do {
                let requestID = http.value(forHTTPHeaderField: "request-id")
                finish(.success(try Self.parseResponse(data ?? Data(), requestID: requestID)))
            } catch {
                finish(.failure(error))
            }
        }
        task.resume()
    }

    public func play(_ audio: SpokenAudio, volume: Double,
                     onStarted: @escaping () -> Void, onFinished: @escaping () -> Void) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
              audio.pcm.count >= 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(audio.pcm.count / 2))
        else {
            onStarted()
            onFinished()
            return
        }
        let frames = audio.pcm.count / 2
        buffer.frameLength = AVAudioFrameCount(frames)
        audio.pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let out = buffer.floatChannelData![0]
            for i in 0..<frames {
                out[i] = Float(Int16(littleEndian: samples[i])) / 32768
            }
        }
        if !engineReady {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engineReady = true
        }
        // Only re-invoke AudioUnitSetProperty when the resolved target actually
        // changed. Setting it on every play() would re-trigger the engine's
        // configuration-change path (see init) — the same lost-completion risk
        // this file's comment warns about — for what is usually a no-op after
        // the first sentence. outputDeviceName is live-reloadable, so we gate
        // on the resolved device, not just "did we ever apply one".
        if !outputDeviceName.isEmpty,
           let dev = AudioOutputDevice.find(named: outputDeviceName),
           dev != appliedDeviceID,
           let unit = engine.outputNode.audioUnit {
            var deviceID = dev
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &deviceID,
                                           UInt32(MemoryLayout<AudioDeviceID>.size))
            if err == noErr {
                appliedDeviceID = dev
            } else {
                NSLog("speech: failed to select output device '%@' (%d)", outputDeviceName, err)
            }
        } else if outputDeviceName.isEmpty, appliedDeviceID != nil,
                  let unit = engine.outputNode.audioUnit {
            // voice.outputDevice was live-reloaded back to "" — the audio unit is
            // still pinned to the old device (nothing else reverts it), so
            // explicitly reselect the system default output. Same no-verify-
            // in-tests boundary as the pin above (manual verification only).
            if let defaultDevice = AudioOutputDevice.systemDefaultOutput() {
                var deviceID = defaultDevice
                let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                               kAudioUnitScope_Global, 0, &deviceID,
                                               UInt32(MemoryLayout<AudioDeviceID>.size))
                if err == noErr {
                    appliedDeviceID = nil
                } else {
                    NSLog("speech: failed to revert output device to system default (%d)", err)
                    // Leave appliedDeviceID set so this retries on the next play().
                }
            } else {
                NSLog("speech: failed to query system default output device")
                // Leave appliedDeviceID set so this retries on the next play().
            }
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                NSLog("speech: audio engine failed to start: %@", "\(error)")
                onStarted()
                onFinished()
                return
            }
        }
        engine.mainMixerNode.outputVolume = Float(max(0, min(1, volume)))
        player.scheduleBuffer(buffer, at: nil, options: [],
                              completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async(execute: onFinished)
        }
        player.play()
        onStarted()
    }

    public func stopPlayback() {
        // Note: stop() fires the scheduled buffer's completion; the coordinator's
        // generation guard discards it.
        player.stop()
    }
}
