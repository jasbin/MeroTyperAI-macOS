import AppKit
import Observation
import OSLog

/// Hotkey to microphone to Whisper to the focused app. Dictations finish in the order they were spoken,
/// and a new one can start while the last is still being transcribed.
@MainActor
@Observable
final class DictationController {
    /// A forgotten hands-free session stops itself after this long.
    static let maxSeconds: Double = 600
    /// Keeps the syllable still in flight when the key comes up.
    private static let tail: Duration = .milliseconds(200)

    private(set) var recording: Recording?
    private(set) var isHandsFree = false
    private(set) var pendingJobs = 0
    private(set) var notice: String?
    @ObservationIgnored var onNeedsSetup: (() -> Void)?

    @ObservationIgnored private let transcriber: Transcriber
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let models: ModelStore
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let monitor = HotkeyMonitor()
    @ObservationIgnored private let hud = HUDController()
    @ObservationIgnored private var gesture = HotkeyGesture()
    @ObservationIgnored private var live: LiveSession?
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var limit: Task<Void, Never>?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?

    init(transcriber: Transcriber, preferences: Preferences, history: HistoryStore, models: ModelStore, permissions: Permissions) {
        self.transcriber = transcriber
        self.preferences = preferences
        self.history = history
        self.models = models
        self.permissions = permissions
        hud.setContent(HUDView(dictation: self))
    }

    var isRecording: Bool { recording != nil }

    /// Returns false until Accessibility access is granted.
    func startMonitoring() -> Bool {
        monitor.key = preferences.hotkey
        monitor.onEvent = { [weak self] in self?.handle($0) }
        return monitor.start()
    }

    func hotkeyChanged() {
        monitor.key = preferences.hotkey
        gesture.reset()
        cancel()
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        let now = ProcessInfo.processInfo.systemUptime
        if let action = gesture.expire(at: now) { perform(action) }
        // A click or keystroke may move the cursor, so live typing must stop editing the field.
        if event == .click || event == .otherKey { live?.freeze() }
        let action: HotkeyGesture.Action? = switch event {
        case .down: gesture.press(at: now)
        case .up: gesture.release(at: now)
        case .otherKey: gesture.interrupt()
        case .escape: gesture.escape()
        case .click: nil
        }
        if let action { perform(action) }
        if case .awaitingSecondTap(let until) = gesture.phase {
            expiry?.cancel()
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(until - now + 0.01))
                guard !Task.isCancelled, let self, let action = gesture.expire(at: ProcessInfo.processInfo.systemUptime) else { return }
                perform(action)
            }
        }
    }

    private func perform(_ action: HotkeyGesture.Action) {
        switch action {
        case .start: begin()
        case .lock:
            isHandsFree = true
        case .finish: finish()
        case .cancel: cancel()
        }
    }

    private func begin() {
        guard recording == nil else { return }
        permissions.refresh()
        // Without Accessibility macOS drops the ⌘V, so stop here instead of recording text that can't be typed.
        guard models.isReady, permissions.allGranted else {
            gesture.reset()
            show(
                models.isBusy ? String(localized: "Mero Typer is still setting up")
                    : !permissions.accessibility ? String(localized: "Allow Accessibility so Mero Typer can type")
                    : String(localized: "Finish setup to dictate")
            )
            onNeedsSetup?()
            return
        }
        do {
            recording = try Recording(microphone: preferences.microphone)
        } catch {
            Logger.app.error("Microphone failed: \(String(describing: error), privacy: .public)")
            gesture.reset()
            show(String(localized: "The microphone isn't available"))
            return
        }
        isHandsFree = false
        if preferences.liveTyping, let recording {
            let session = LiveSession(
                recording: recording, transcriber: transcriber, language: preferences.language,
                vocabulary: preferences.vocabulary, removeFillers: preferences.removeFillers
            )
            session.start(after: queue)
            live = session
        }
        dismissNotice()
        play("Tink")
        limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxSeconds))
            guard !Task.isCancelled, let self else { return }
            gesture.reset()
            finish()
        }
        refreshHUD()
    }

    private func finish() {
        guard let recording else { return }
        self.recording = nil
        isHandsFree = false
        limit?.cancel()
        play("Pop")
        pendingJobs += 1
        refreshHUD()
        let previous = queue
        let session = live
        live = nil
        let language = preferences.language
        let vocabulary = preferences.vocabulary
        queue = Task {
            try? await Task.sleep(for: Self.tail)
            let samples = recording.stop()
            await previous?.value
            if let session {
                await finishLive(session, samples: samples)
            } else {
                await process(samples, language: language, vocabulary: vocabulary)
            }
            pendingJobs -= 1
            refreshHUD()
        }
    }

    private func cancel() {
        expiry?.cancel()
        limit?.cancel()
        live?.cancel()
        live = nil
        guard let recording else { return }
        _ = recording.stop()
        self.recording = nil
        isHandsFree = false
        refreshHUD()
    }

    private func finishLive(_ session: LiveSession, samples: [Float]) async {
        do {
            let start = Date.now
            guard let result = try await session.finish(samples) else {
                show(String(localized: "No speech heard"))
                return
            }
            Logger.app.notice("Live dictation finished \(Date.now.timeIntervalSince(start), format: .fixed(precision: 2))s after release")
            if preferences.keepHistory { history.add(result.text) }
            if !result.isTyped {
                TextInserter.copy(result.text)
                show(String(localized: "You moved the cursor, so the text was copied. Press ⌘V to paste."))
            }
        } catch {
            Logger.app.error("Transcription failed: \(String(describing: error), privacy: .public)")
            play("Basso")
            show(error.localizedDescription)
        }
    }

    private func process(_ samples: [Float], language: String, vocabulary: String) async {
        guard SpeechGate.hasSpeech(samples) else {
            show(String(localized: "No speech heard"))
            return
        }
        do {
            let start = Date.now
            let transcript = try await transcriber.transcribe(samples, language: language, vocabulary: vocabulary)
            let seconds = Double(samples.count) / Double(SpeechGate.sampleRate)
            Logger.app.notice("Transcribed \(seconds, format: .fixed(precision: 1))s of audio in \(Date.now.timeIntervalSince(start), format: .fixed(precision: 2))s")
            let text = TextCleaner.clean(transcript.text, language: language, removeFillers: preferences.removeFillers)
            guard !text.isEmpty else {
                show(String(localized: "No speech heard"))
                return
            }
            if preferences.keepHistory { history.add(text) }
            if await TextInserter.insert(TextCleaner.forTyping(text, language: language)) == .copied {
                show(String(localized: "Copied. Press ⌘V to paste."))
            }
        } catch {
            Logger.app.error("Transcription failed: \(String(describing: error), privacy: .public)")
            play("Basso")
            show(error.localizedDescription)
        }
    }

    private func show(_ message: String) {
        notice = message
        refreshHUD()
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.dismissNotice()
        }
    }

    private func dismissNotice() {
        noticeTimer?.cancel()
        notice = nil
        refreshHUD()
    }

    private func refreshHUD() {
        if isRecording || pendingJobs > 0 || notice != nil { hud.show() } else { hud.hide() }
    }

    private func play(_ name: String) {
        guard preferences.playSounds, let sound = NSSound(named: name) else { return }
        sound.volume = 0.3
        sound.play()
    }
}
