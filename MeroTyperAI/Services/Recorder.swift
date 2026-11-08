import Foundation
import os
import WhisperKit

/// Collects the 16 kHz mono buffers that arrive on the audio thread.
final class SampleBuffer: Sendable {
    private struct State {
        var samples: [Float] = []
        var level: Float = 0
        var listener: (@Sendable ([Float]) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ chunk: [Float]) {
        let level = SpeechGate.rms(chunk)
        state.withLock {
            $0.samples.append(contentsOf: chunk)
            $0.level = level
            $0.listener?(chunk)
        }
    }

    /// Sends everything recorded so far, then each new chunk, in order. The listener must return quickly.
    func listen(_ listener: (@Sendable ([Float]) -> Void)?) {
        state.withLock {
            $0.listener = listener
            if let listener, !$0.samples.isEmpty { listener($0.samples) }
        }
    }

    /// Loudness of the latest buffer, for the on-screen meter.
    var level: Float { state.withLock { $0.level } }
    var samples: [Float] { state.withLock { $0.samples } }
    var count: Int { state.withLock { $0.samples.count } }
}

/// One take. Each take builds a fresh engine, so it follows microphone changes between dictations.
@MainActor
final class Recording {
    let buffer = SampleBuffer()
    let startedAt = Date.now
    private let processor = AudioProcessor()

    /// An empty name, or a microphone that's gone, means the system default input.
    init(microphone: String) throws {
        let device = microphone.isEmpty ? nil : AudioProcessor.getAudioDevices().first { $0.name == microphone }?.id
        let buffer = self.buffer
        try processor.startRecordingLive(inputDeviceID: device) { buffer.append($0) }
    }

    func stop() -> [Float] {
        processor.stopRecording()
        return buffer.samples
    }
}

/// Skips Whisper on silence, where it tends to invent phrases like "Thank you."
enum SpeechGate {
    static let sampleRate = 16_000
    /// About -46 dBFS: room noise stays below it, speech goes well above.
    static let threshold: Float = 0.005
    static let minimumSeconds = 0.3

    static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    static func hasSpeech(_ samples: [Float]) -> Bool {
        guard Double(samples.count) >= minimumSeconds * Double(sampleRate) else { return false }
        let window = sampleRate / 10
        return stride(from: 0, to: samples.count, by: window).contains { start in
            rms(samples[start..<min(start + window, samples.count)]) > threshold
        }
    }
}
