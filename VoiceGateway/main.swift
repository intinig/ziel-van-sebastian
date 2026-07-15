import Foundation
import CWhisper

// voice-gateway: mic → VAD → segmenter → whisper → events on ws://127.0.0.1:<port>
// Reads the same config.json as the app (voice section). See docs/voice-gateway.md.

let configURL = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? ZielConfig.defaultURL
let config = ZielConfig.load(from: configURL).voice
let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Ziel van Sebastian/models")
let sttPath = config.modelPath.isEmpty
    ? modelsDir.appendingPathComponent("ggml-\(config.model).bin").path : config.modelPath
let vadPath = config.vadModelPath.isEmpty
    ? modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin").path : config.vadModelPath
// URL(string:)?.port is Int?; UInt16(exactly:) avoids trapping on an out-of-range
// or malformed port in a hand-edited config — fall back to the documented default.
let port = URL(string: config.gatewayURL)?.port.flatMap { UInt16(exactly: $0) } ?? 18790

func log(_ s: String) { FileHandle.standardError.write(Data("[voice-gateway] \(s)\n".utf8)) }

do {
    let stt = try WhisperSTT(modelPath: sttPath, languages: config.languages)
    let vad = try SileroVAD(modelPath: vadPath)
    let server = try VoiceGatewayServer(requestedPort: port)
    let segmenter = UtteranceSegmenter()
    let voiceQueue = DispatchQueue(label: "voice-pipeline")

    let pipeline = VoicePipeline(
        wakeWord: config.wakeWord,
        transcribe: { stt.transcribe($0) },
        emit: { event in
            log("event: \(event)")
            server.broadcast(event)
        })

    server.onCommand = { cmd in
        voiceQueue.async {
            log("command: \(cmd)")
            pipeline.handle(cmd, resetSegmenter: { segmenter.reset(); vad.reset() })
        }
    }

    let capture = AudioCapture(deviceName: config.inputDevice) { frame in
        voiceQueue.async {
            let prob = vad.speechProbability(frame512: frame)
            if let e = segmenter.push(frame: frame, prob: prob) { pipeline.segmenterEvent(e) }
        }
    }

    try server.start()
    log("listening on ws://127.0.0.1:\(server.port), model=\(sttPath)")
    try capture.start()
    log("mic capture running (device: \(config.inputDevice.isEmpty ? "system default" : config.inputDevice))")
    dispatchMain()
} catch {
    log("fatal: \(error.localizedDescription)")
    exit(1)
}
