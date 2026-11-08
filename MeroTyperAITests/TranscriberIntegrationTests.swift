import Foundation
import Testing
import WhisperKit
@testable import MeroTyperAI

/// Runs Whisper Large V3 Turbo on a short spoken fixture (made with `say`, see README).
/// Needs the model the app downloads, so it's opt-in:
/// TEST_RUNNER_MERO_E2E=1 xcodebuild test -scheme MeroTyperAI -only-testing:MeroTyperAITests/TranscriberIntegrationTests
@Suite(.serialized)
struct TranscriberIntegrationTests {
    private static let isEnabled = ProcessInfo.processInfo.environment["MERO_E2E"] != nil
    private final class BundleToken {}

    @Test(.enabled(if: isEnabled))
    func spokenSentenceBecomesTypedText() async throws {
        try #require(SpeechModel.filesAreComplete, "Download the model in Mero Typer first")
        let fixture = try #require(Bundle(for: BundleToken.self).url(forResource: "dictation", withExtension: "wav"))
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fixture.path)
        #expect(SpeechGate.hasSpeech(samples))

        let transcriber = Transcriber()
        let loadStart = Date.now
        try await transcriber.prepare()
        print("E2E load seconds: \(Date.now.timeIntervalSince(loadStart))")

        let start = Date.now
        let transcript = try await transcriber.transcribe(samples, language: "en", vocabulary: "")
        let elapsed = Date.now.timeIntervalSince(start)
        let text = TextCleaner.clean(transcript.text, language: "en", removeFillers: true)
        print("E2E \(elapsed)s for \(Double(samples.count) / 16_000)s of audio: \(text)")

        #expect(text.lowercased().contains("design review"))
        #expect(text.lowercased().contains("thursday"))
        #expect(elapsed < 5, "Dictation should feel instant on Apple silicon")

        // The vocabulary goes in as Whisper's prompt.
        let hinted = try await transcriber.transcribe(samples, language: "en", vocabulary: "Sam, design review")
        #expect(hinted.text.lowercased().contains("thursday"))

        // Live typing locks in segments by their end times, so those must be real times inside the audio.
        let twice = samples + [Float](repeating: 0, count: 8_000) + samples
        let liveStart = Date.now
        let timed = try await transcriber.transcribe(twice, language: "en", vocabulary: "", timestamps: true)
        let duration = Double(twice.count) / 16_000
        print("E2E timed pass \(Date.now.timeIntervalSince(liveStart))s, segments: \(timed.segments.map { "\($0.start)-\($0.end)" })")
        #expect(timed.segments.count >= 2)
        #expect(timed.segments.allSatisfy { $0.start <= $0.end && $0.end <= duration + 0.5 })
        #expect(zip(timed.segments, timed.segments.dropFirst()).allSatisfy { $0.end <= $1.start + 0.5 })

        // Partial audio, as live typing sees it mid-sentence.
        let half = try await transcriber.transcribe(Array(samples.prefix(samples.count / 2)), language: "en", vocabulary: "", timestamps: true)
        print("E2E half: \(half.text)")
        #expect(half.text.lowercased().contains("sam"))

        // Another language, set by the user.
        let french = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: try #require(Bundle(for: BundleToken.self).url(forResource: "french", withExtension: "wav")).path
        )
        let frenchText = try await transcriber.transcribe(french, language: "fr", vocabulary: "").text
        print("E2E french: \(frenchText)")
        #expect(frenchText.lowercased().contains("jeudi"))
        await transcriber.unload()
    }

    /// Live preview: words must show up while audio is still arriving, including audio recorded before it started.
    @MainActor
    @Test(.enabled(if: isEnabled))
    func applePreviewStreamsWhileYouSpeak() async throws {
        guard #available(macOS 26, *) else { return }
        let fixture = try #require(Bundle(for: BundleToken.self).url(forResource: "dictation", withExtension: "wav"))
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fixture.path)
        final class Updates { var list: [(seconds: Double, text: String)] = [] }
        let updates = Updates()
        let buffer = SampleBuffer()
        buffer.append(Array(samples.prefix(8_000)))
        let start = Date.now
        let preview = try #require(await ApplePreview.start(language: "en", buffer: buffer) { text in
            updates.list.append((Date.now.timeIntervalSince(start), text))
        })
        for offset in stride(from: 8_000, to: samples.count, by: 1_600) {
            buffer.append(Array(samples[offset..<min(offset + 1_600, samples.count)]))
            try await Task.sleep(for: .milliseconds(100))
        }
        let fedAt = Date.now.timeIntervalSince(start)
        try await Task.sleep(for: .seconds(1))
        await preview.stop()
        for update in updates.list { print("E2E preview \(String(format: "%.2f", update.seconds))s: \(update.text)") }
        print("E2E preview audio fed by \(String(format: "%.2f", fedAt))s")

        #expect(updates.list.first?.text.contains("Hi") == true, "Replays audio recorded before the preview started")
        #expect(updates.list.contains { $0.seconds < fedAt - 1 && $0.text.lowercased().contains("design") }, "Text arrives while audio is still coming in")
        #expect(updates.list.last?.text.lowercased().contains("thursday") == true)
    }
}
