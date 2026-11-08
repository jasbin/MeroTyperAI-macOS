import Foundation
import OSLog
import WhisperKit

extension Logger {
    /// Timings and errors only. Dictated text and audio never go in the log.
    static let app = Logger(subsystem: "com.merotyper.app", category: "dictation")
}

enum ModelFilesError: LocalizedError {
    case incomplete

    var errorDescription: String? {
        String(localized: "The speech model is incomplete. Delete it in Settings, then download it again.")
    }
}

/// OpenAI Whisper Large V3 Turbo, as Argmax's Core ML build.
enum SpeechModel {
    static let variant = "large-v3-v20240930_turbo_632MB"
    static let root = AppPaths.models.appending(path: "models", directoryHint: .isDirectory)
    static let folder = root.appending(path: "argmaxinc/whisperkit-coreml/openai_whisper-\(variant)", directoryHint: .isDirectory)

    private static let requiredFiles: [URL] = ["AudioEncoder", "MelSpectrogram", "TextDecoder", "TextDecoderContextPrefill"].flatMap { model in
        ["coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"].map { folder.appending(path: "\(model).mlmodelc/\($0)") }
    }

    /// Core ML crashes on a model with missing files instead of throwing, so check before every load.
    static var filesAreComplete: Bool {
        requiredFiles.allSatisfy { file in
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 ?? 0
            return size > 0
        }
    }

    /// Loading from the local folder keeps dictation working offline.
    static func config(prewarm: Bool) -> WhisperKitConfig {
        WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: AppPaths.models,
            verbose: false,
            prewarm: prewarm,
            load: true,
            download: false
        )
    }
}

struct Transcript: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        /// Seconds from the start of the audio passed in.
        var start: Double
        var end: Double
        var text: String
    }

    var text: String
    var segments: [Segment] = []
}

/// Keeps one Whisper instance in memory, so each dictation pays only for decoding.
actor Transcriber {
    /// WhisperKit isn't Sendable. The actor is its only owner, and callers run one job at a time.
    private final class Loaded: @unchecked Sendable {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
    }

    private var loading: Task<Loaded, any Error>?

    func prepare() async throws {
        _ = try await loaded()
    }

    func unload() async {
        guard let task = loading else { return }
        loading = nil
        if let loaded = try? await task.value {
            nonisolated(unsafe) let kit = loaded.kit
            await kit.unloadModels()
        }
    }

    /// `timestamps` gives segment times, which live typing needs to lock in finished sentences.
    func transcribe(_ samples: [Float], language: String, vocabulary: String, timestamps: Bool = false) async throws -> Transcript {
        nonisolated(unsafe) let kit = try await loaded().kit
        var options = DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: !timestamps,
            // The VAD chunker drops clips around a second long, so it's only for audio near Whisper's 30 s window.
            chunkingStrategy: samples.count > 25 * SpeechGate.sampleRate ? .vad : nil
        )
        let hint = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty, let tokenizer = kit.tokenizer {
            // Whisper treats the prompt as earlier text, which nudges it toward these spellings.
            options.promptTokens = tokenizer.encode(text: " " + hint).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return Transcript(
            text: results.map(\.text).joined(separator: " "),
            segments: results.flatMap(\.segments).map { .init(start: Double($0.start), end: Double($0.end), text: $0.text) }
        )
    }

    private func loaded() async throws -> Loaded {
        if loading == nil {
            guard SpeechModel.filesAreComplete else { throw ModelFilesError.incomplete }
            loading = Task {
                let start = Date.now
                let kit = try await WhisperKit(SpeechModel.config(prewarm: false))
                Logger.app.notice("Speech model loaded in \(Date.now.timeIntervalSince(start), format: .fixed(precision: 1))s")
                return Loaded(kit)
            }
        }
        do {
            return try await loading!.value
        } catch {
            loading = nil
            throw error
        }
    }
}

