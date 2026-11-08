import AppKit
import Carbon.HIToolbox
import OSLog

/// Text edits behind live typing.
enum LiveText {
    /// How to turn `old` into `new` from the end: Backspace this many characters, then type the rest.
    static func edit(from old: String, to new: String) -> (deletions: Int, insertion: String) {
        let common = zip(old, new).prefix { $0 == $1 }.count
        return (old.count - common, String(new.dropFirst(common)))
    }

    /// The opening words two passes agree on. Waiting for agreement keeps the half-heard last word
    /// from flickering in the user's field.
    static func agreement(_ first: String, _ second: String) -> String {
        zip(first.split(separator: " "), second.split(separator: " "))
            .prefix { $0 == $1 }
            .map { String($0.0) }
            .joined(separator: " ")
    }

    /// What to show from a pass: every word but the last, which is often still being spoken.
    /// Once two passes agree on the whole thing, the last word shows too.
    static func stable(previous: String, current: String) -> String {
        let agreed = agreement(previous, current)
        let allButLast = current.split(separator: " ").dropLast().joined(separator: " ")
        // Both are word prefixes of `current`, so the longer one holds the shorter.
        return agreed.count >= allButLast.count ? agreed : allButLast
    }

    static func joined(_ parts: String...) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Types a dictation into the focused field while the user speaks, then corrects it with Whisper's final text.
/// The live text comes from Apple's streaming recognizer when it knows the language, else from repeated Whisper passes.
/// It edits only text it typed itself. If the user clicks, types, or switches apps, it stops editing.
@MainActor
final class LiveSession {
    /// New audio needed before another pass. A pass takes about 0.6 s, so passes run back to back.
    private static let step = SpeechGate.sampleRate * 3 / 10
    /// Past this, finished sentences are locked in, so passes stay fast and early text stops changing.
    private static let lockAfterSeconds = 10.0

    private let recording: Recording
    private let transcriber: Transcriber
    private let vocabulary: String
    private let removeFillers: Bool
    private let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private let language: String
    private var typed = ""
    private var lockedText = ""
    private var lockedSamples = 0
    private var lastHypothesis = ""
    private var loop: Task<Void, Never>?
    private var stopPreview: (() async -> Void)?
    private var isPreviewing = false
    private var pendingPreview: String?
    private(set) var isFrozen = false

    init(recording: Recording, transcriber: Transcriber, language: String, vocabulary: String, removeFillers: Bool) {
        self.recording = recording
        self.transcriber = transcriber
        self.language = language
        self.vocabulary = vocabulary
        self.removeFillers = removeFillers
    }

    /// Waits for the previous dictation to finish typing, so two never edit the field at once.
    func start(after previous: Task<Void, Never>?) {
        loop = Task { [self] in
            await previous?.value
            if #available(macOS 26, *) {
                isPreviewing = true
                let preview = await ApplePreview.start(language: language, buffer: recording.buffer) { [weak self] in self?.showPreview($0) }
                if let preview {
                    if Task.isCancelled { await preview.stop() } else { stopPreview = { await preview.stop() } }
                    return
                }
                isPreviewing = false
            }
            var processed = 0
            while !Task.isCancelled {
                guard recording.buffer.count - processed >= Self.step else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                let samples = recording.buffer.samples
                processed = samples.count
                do {
                    guard let hypothesis = try await pass(samples), !Task.isCancelled else { continue }
                    let shown = LiveText.stable(previous: lastHypothesis, current: hypothesis)
                    lastHypothesis = hypothesis
                    // Don't erase words just because this pass is shorter.
                    if !typed.hasPrefix(shown) { apply(shown) }
                } catch is CancellationError {
                    return
                } catch {
                    Logger.app.error("Live pass failed: \(String(describing: error), privacy: .public)")
                    return
                }
            }
        }
    }

    /// Stops editing for good, because the cursor may no longer be where the typed text ends.
    func freeze() {
        isFrozen = true
    }

    /// Final pass over the whole take. Returns the text, and whether it's in the field.
    func finish(_ samples: [Float]) async throws -> (text: String, isTyped: Bool)? {
        isPreviewing = false
        loop?.cancel()
        await loop?.value
        await stopPreview?()
        stopPreview = nil
        let rest = Array(samples.dropFirst(lockedSamples))
        var restText = ""
        if SpeechGate.hasSpeech(rest) {
            restText = try await transcriber.transcribe(rest, language: language, vocabulary: vocabulary).text
        }
        let text = clean(LiveText.joined(lockedText, restText))
        guard !text.isEmpty else {
            undo()
            return nil
        }
        return (text, apply(TextCleaner.forTyping(text, language: language)))
    }

    /// Removes what this dictation typed, unless the user has moved on.
    func cancel() {
        isPreviewing = false
        loop?.cancel()
        if let stopPreview { Task { await stopPreview() } }
        stopPreview = nil
        undo()
    }

    /// Results arrive in bursts, a final one then fresh guesses. Typing only the last of a burst avoids flicker.
    private func showPreview(_ text: String) {
        let isScheduled = pendingPreview != nil
        pendingPreview = text
        guard !isScheduled else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            if isPreviewing, let text = pendingPreview { apply(clean(text)) }
            pendingPreview = nil
        }
    }

    private func undo() {
        guard !isFrozen, !typed.isEmpty else { return }
        apply("")
    }

    private func pass(_ samples: [Float]) async throws -> String? {
        let window = Array(samples.dropFirst(lockedSamples))
        guard SpeechGate.hasSpeech(window) else { return nil }
        let transcript = try await transcriber.transcribe(window, language: language, vocabulary: vocabulary, timestamps: true)
        let seconds = Double(window.count) / Double(SpeechGate.sampleRate)
        var segments = transcript.segments
        if seconds > Self.lockAfterSeconds, segments.count > 2 {
            let finished = segments.prefix(segments.count - 2)
            let end = min(Int((finished.last?.end ?? 0) * Double(SpeechGate.sampleRate)), window.count)
            if end > 0 {
                lockedText = LiveText.joined(lockedText, finished.map(\.text).joined(separator: " "))
                lockedSamples += end
                segments.removeFirst(finished.count)
            }
        }
        return clean(LiveText.joined(lockedText, segments.map(\.text).joined(separator: " ")))
    }

    private func clean(_ text: String) -> String {
        TextCleaner.clean(text, language: language, removeFillers: removeFillers)
    }

    /// Edits the field from what's typed to `target`. Returns false once editing isn't safe anymore.
    @discardableResult
    private func apply(_ target: String) -> Bool {
        if !isFrozen, NSWorkspace.shared.frontmostApplication?.processIdentifier != app || IsSecureEventInputEnabled() {
            isFrozen = true
        }
        guard !isFrozen else { return false }
        let edit = LiveText.edit(from: typed, to: target)
        TextInserter.deleteBackward(edit.deletions)
        TextInserter.type(edit.insertion)
        typed = target
        return true
    }
}
