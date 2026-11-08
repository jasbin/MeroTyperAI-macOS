import AVFoundation
import OSLog
import Speech

/// Apple's on-device streaming recognizer, used only for the live preview while the user speaks.
/// It reports words about half a second after they're said, where each Whisper pass takes 0.5 s on its own.
/// Whisper still writes the final text when the user lets go.
@available(macOS 26, *)
@MainActor
final class ApplePreview {
    private static var installing: Set<String> = []

    private let analyzer: SpeechAnalyzer
    private let buffer: SampleBuffer
    private let audio: AsyncStream<[Float]>.Continuation
    private let feeder: Task<Void, Never>
    private let reader: Task<Void, Never>

    /// Returns nil when Apple's recognizer can't preview this language yet. A supported language that isn't
    /// on this Mac starts downloading in the background, and Whisper previews until it's ready.
    static func start(language: String, buffer: SampleBuffer, onText: @escaping @MainActor (String) -> Void) async -> ApplePreview? {
        // The Mac's own region first, so English is US English here rather than any English.
        let wanted = Locale.current.language.languageCode?.identifier == language ? Locale.current : Locale(identifier: language)
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            install(locale)
            return nil
        }
        do {
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
            try await analyzer.prepareToAnalyze(in: format)
            let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: inputs)
            return ApplePreview(analyzer: analyzer, transcriber: transcriber, format: format, input: input, buffer: buffer, onText: onText)
        } catch {
            Logger.app.error("Live preview unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private init(
        analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat,
        input: AsyncStream<AnalyzerInput>.Continuation, buffer: SampleBuffer, onText: @escaping @MainActor (String) -> Void
    ) {
        self.analyzer = analyzer
        self.buffer = buffer
        let (chunks, audio) = AsyncStream<[Float]>.makeStream()
        self.audio = audio
        feeder = Task.detached(priority: .userInitiated) {
            let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            guard let converter = AVAudioConverter(from: source, to: format) else { return }
            for await chunk in chunks {
                if let converted = Self.convert(chunk, from: source, with: converter) { input.yield(AnalyzerInput(buffer: converted)) }
            }
            input.finish()
        }
        let results = transcriber.results
        reader = Task {
            var finished = ""
            do {
                // A volatile result is the best guess for audio after the last final one, and replaces the previous guess.
                for try await result in results {
                    let text = String(result.text.characters)
                    if result.isFinal { finished += text }
                    onText(finished + (result.isFinal ? "" : text))
                }
            } catch {
                Logger.app.error("Live preview stopped: \(String(describing: error), privacy: .public)")
            }
        }
        // Replays what was recorded while this started, so the first words aren't lost.
        buffer.listen { audio.yield($0) }
    }

    func stop() async {
        buffer.listen(nil)
        audio.finish()
        reader.cancel()
        feeder.cancel()
        await analyzer.cancelAndFinishNow()
    }

    private static func install(_ locale: Locale) {
        guard installing.insert(locale.identifier).inserted else { return }
        Task {
            do {
                _ = try await AssetInventory.reserve(locale: locale)
                let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                try await AssetInventory.assetInstallationRequest(supporting: [module])?.downloadAndInstall()
                Logger.app.notice("Installed live preview for \(locale.identifier, privacy: .public)")
            } catch {
                Logger.app.error("Live preview download failed: \(String(describing: error), privacy: .public)")
                installing.remove(locale.identifier)
            }
        }
    }

    private nonisolated static func convert(_ chunk: [Float], from source: AVAudioFormat, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard !chunk.isEmpty, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(chunk.count)) else { return nil }
        input.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
        let capacity = AVAudioFrameCount(Double(chunk.count) * converter.outputFormat.sampleRate / source.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }
}
