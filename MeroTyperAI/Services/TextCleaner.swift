import Foundation

/// Turns raw Whisper output into text ready to type.
enum TextCleaner {
    /// Spoken hesitations. English only: "um" is a real word in Portuguese.
    static let englishFillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "hmm"]
    /// Languages written without spaces between sentences.
    private static let unspacedLanguages: Set<String> = ["zh", "yue", "ja", "th", "lo", "my", "km"]

    static func clean(_ raw: String, language: String?, removeFillers: Bool) -> String {
        let text = raw
            .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            // Sound tags such as [BLANK_AUDIO] or [Music].
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A lone "(music)" is a sound, not speech. "We (all) agreed" stays.
        if text.range(of: #"^\([^)]*\)$"#, options: .regularExpression) != nil { return "" }
        return removeFillers && language == "en" ? withoutFillers(text) : text
    }

    /// Adds a trailing space, so the next dictation doesn't run into this one.
    static func forTyping(_ text: String, language: String?) -> String {
        unspacedLanguages.contains(language ?? "") ? text : text + " "
    }

    static func withoutFillers(_ text: String) -> String {
        var words: [String] = []
        var capitalizeNext = false
        for token in text.split(separator: " ") {
            let core = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard englishFillers.contains(core) else {
                var word = String(token)
                if capitalizeNext {
                    word = word.prefix(1).uppercased() + word.dropFirst()
                    capitalizeNext = false
                }
                words.append(word)
                continue
            }
            let endsSentence: (String) -> Bool = { $0.last.map { ".!?".contains($0) } ?? false }
            if words.last.map(endsSentence) ?? true { capitalizeNext = true }
            // "Ship it, uh." keeps its full stop: "Ship it."
            if let end = token.last, ".!?".contains(end), let previous = words.last, !endsSentence(previous) {
                words[words.count - 1] = previous.trimmingCharacters(in: CharacterSet(charactersIn: ",;:")) + String(end)
            }
        }
        return words.joined(separator: " ")
    }
}
