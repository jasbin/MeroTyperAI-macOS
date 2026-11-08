import Foundation
import Observation
import OSLog
import WhisperKit

/// Owns the first-run download of the speech model and its first load, which optimizes it for this Mac.
@MainActor
@Observable
final class ModelStore {
    enum State: Equatable {
        case missing
        case downloading(Double)
        case optimizing
        case ready
        case failed(String)
    }

    static let requiredBytes: Int64 = 1_200_000_000
    private static let readyKey = "speechModelReady"
    private static let requestedKey = "speechModelRequested"
    private static let autoResumesKey = "speechModelAutoResumes"
    private static let maxAutoResumes = 3

    private(set) var state: State
    private let transcriber: Transcriber

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
        let flagged = UserDefaults.standard.bool(forKey: Self.readyKey)
        state = flagged && SpeechModel.filesAreComplete ? .ready : .missing
    }

    var isReady: Bool { state == .ready }

    var isBusy: Bool {
        switch state {
        case .downloading, .optimizing: true
        default: false
        }
    }

    func prepare() {
        guard !isBusy, !isReady else { return }
        guard AppPaths.freeBytes >= Self.requiredBytes else {
            state = .failed(String(localized: "Free up at least 1.2 GB on this Mac, then try again."))
            return
        }
        UserDefaults.standard.set(true, forKey: Self.requestedKey)
        state = .downloading(0)
        Task {
            do {
                let downloadStart = Date.now
                try await Self.download { fraction in
                    Task { @MainActor in self.report(fraction) }
                }
                Logger.app.notice("Model downloaded in \(Date.now.timeIntervalSince(downloadStart), format: .fixed(precision: 1))s")
                state = .optimizing
                // The first load compiles the model for this Mac's Neural Engine and caches the tokenizer,
                // so later launches load fast and work offline. The model then stays loaded.
                let optimizeStart = Date.now
                try await transcriber.prepare()
                Logger.app.notice("Model optimized in \(Date.now.timeIntervalSince(optimizeStart), format: .fixed(precision: 1))s")
                UserDefaults.standard.set(true, forKey: Self.readyKey)
                UserDefaults.standard.set(0, forKey: Self.autoResumesKey)
                state = .ready
            } catch {
                Logger.app.error("Model setup failed: \(String(describing: error), privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Continues a setup the user already started, after the app quit partway through.
    func resumeIfRequested() {
        let defaults = UserDefaults.standard
        guard state == .missing, defaults.bool(forKey: Self.requestedKey) else { return }
        // The cap stops a crash during setup from turning into a crash on every launch.
        let attempts = defaults.integer(forKey: Self.autoResumesKey)
        guard attempts < Self.maxAutoResumes else { return }
        defaults.set(attempts + 1, forKey: Self.autoResumesKey)
        prepare()
    }

    func delete() async {
        guard !isBusy else { return }
        await transcriber.unload()
        UserDefaults.standard.set(false, forKey: Self.readyKey)
        UserDefaults.standard.set(false, forKey: Self.requestedKey)
        try? FileManager.default.removeItem(at: SpeechModel.root)
        state = .missing
    }

    private func report(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(fraction)
    }

    private nonisolated static func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(
            variant: SpeechModel.variant,
            downloadBase: AppPaths.models,
            progressCallback: { onProgress($0.fractionCompleted) }
        )
    }
}
