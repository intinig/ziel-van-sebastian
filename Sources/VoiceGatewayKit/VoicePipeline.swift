import Foundation

/// Mode-aware glue between the segmenter and the wire: decides which utterances
/// become events. Pure — audio, STT, and the WS server are injected/adjacent.
public final class VoicePipeline {
    public var mode: WakeMode = .armed
    private var segmentOpen = false
    private let wakeWord: String
    private let transcribe: ([Float]) -> String
    private let emit: (VoiceEvent) -> Void

    public init(wakeWord: String,
                transcribe: @escaping ([Float]) -> String,
                emit: @escaping (VoiceEvent) -> Void) {
        self.wakeWord = wakeWord
        self.transcribe = transcribe
        self.emit = emit
    }

    public func segmenterEvent(_ e: UtteranceSegmenter.Event) {
        switch e {
        case .started:
            segmentOpen = true
            emit(.vad(speaking: true))
        case .utterance(let samples):
            segmentOpen = false
            emit(.vad(speaking: false))
            let text = transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            switch mode {
            case .armed:
                guard let command = WakeWordParser.match(transcript: text, wakeWord: wakeWord) else { return }
                emit(.wake)
                emit(command.isEmpty ? .listening : .heard(text: command))
            case .listen, .followUp, .speaking:
                // Strip a stray leading wake word so "Sebastian, X" mid-conversation still means X.
                let command = WakeWordParser.match(transcript: text, wakeWord: wakeWord) ?? text
                guard !command.isEmpty else { return }
                emit(.heard(text: command))
            }
        }
    }

    public func handle(_ c: VoiceCommand, resetSegmenter: () -> Void) {
        switch c {
        case .mode(let m): mode = m
        case .stop:
            if segmentOpen { emit(.vad(speaking: false)); segmentOpen = false }
            resetSegmenter()
        }
    }
}
