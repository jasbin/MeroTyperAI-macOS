import Foundation
import Observation
import WhisperKit

@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var hotkey: HotkeyKey {
        didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") }
    }
    /// The Whisper language code to transcribe in. Whisper's auto-detect mixes up similar languages, so the user picks.
    var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }
    /// Words Whisper should spell the user's way, passed as its prompt.
    var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: "vocabulary") }
    }
    /// A microphone name. Empty means the system default input.
    var microphone: String {
        didSet { defaults.set(microphone, forKey: "microphone") }
    }
    /// Types while the user speaks. Off pastes everything once they finish, which suits apps that garble typed input.
    var liveTyping: Bool {
        didSet { defaults.set(liveTyping, forKey: "liveTyping") }
    }
    var removeFillers: Bool {
        didSet { defaults.set(removeFillers, forKey: "removeFillers") }
    }
    var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: "playSounds") }
    }
    var keepHistory: Bool {
        didSet { defaults.set(keepHistory, forKey: "keepHistory") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = HotkeyKey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        // Earlier builds saved an empty string for auto-detect, which no longer exists.
        let saved = defaults.string(forKey: "language") ?? ""
        language = saved.isEmpty ? "en" : saved
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        microphone = defaults.string(forKey: "microphone") ?? ""
        liveTyping = defaults.object(forKey: "liveTyping") as? Bool ?? true
        removeFillers = defaults.object(forKey: "removeFillers") as? Bool ?? true
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        keepHistory = defaults.object(forKey: "keepHistory") as? Bool ?? true
    }
}

enum WhisperLanguages {
    /// Whisper's languages, one name per code, sorted by name.
    static let all: [(code: String, name: String)] =
        Dictionary(Constants.languages.map { ($0.value, $0.key) }) { min($0, $1) }
            .map { (code: $0.key, name: $0.value.capitalized) }
            .sorted { $0.name < $1.name }
}
