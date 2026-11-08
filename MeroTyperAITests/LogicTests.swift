import Foundation
import Testing
@testable import MeroTyperAI

struct HotkeyGestureTests {
    @Test func holdRecordsUntilRelease() {
        var gesture = HotkeyGesture()
        #expect(gesture.press(at: 0) == .start)
        #expect(gesture.release(at: 1) == .finish)
        #expect(gesture.phase == .idle)
    }

    @Test func loneTapIsDiscardedAfterTheWindow() {
        var gesture = HotkeyGesture()
        #expect(gesture.press(at: 0) == .start)
        #expect(gesture.release(at: 0.1) == nil)
        #expect(gesture.expire(at: 0.2) == nil)
        #expect(gesture.expire(at: 0.1 + HotkeyGesture.doubleTapWindow) == .cancel)
        #expect(gesture.phase == .idle)
    }

    @Test func doubleTapLocksHandsFreeAndNextPressFinishes() {
        var gesture = HotkeyGesture()
        #expect(gesture.press(at: 0) == .start)
        #expect(gesture.release(at: 0.1) == nil)
        #expect(gesture.press(at: 0.3) == .lock)
        #expect(gesture.release(at: 0.4) == nil)
        #expect(gesture.phase == .handsFree)
        #expect(gesture.interrupt() == nil, "Typing during hands-free keeps recording")
        #expect(gesture.press(at: 5) == .finish)
        #expect(gesture.release(at: 5.1) == nil)
        #expect(gesture.phase == .idle)
    }

    @Test func shortcutWhileHoldingCancels() {
        var gesture = HotkeyGesture()
        _ = gesture.press(at: 0)
        #expect(gesture.interrupt() == .cancel)
        #expect(gesture.release(at: 1) == nil)
    }

    @Test func escapeCancelsAnyRecording() {
        var gesture = HotkeyGesture()
        #expect(gesture.escape() == nil)
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.1)
        _ = gesture.press(at: 0.2)
        #expect(gesture.escape() == .cancel)
        #expect(gesture.phase == .idle)
    }
}

struct TextCleanerTests {
    @Test func stripsTokensTagsAndSpacing() {
        #expect(TextCleaner.clean("<|en|> Hello   world.<|endoftext|>", language: "en", removeFillers: false) == "Hello world.")
        #expect(TextCleaner.clean(" [BLANK_AUDIO] ", language: "en", removeFillers: true) == "")
        #expect(TextCleaner.clean("(upbeat music)", language: "en", removeFillers: true) == "")
        #expect(TextCleaner.clean("We (all) agreed.", language: "en", removeFillers: true) == "We (all) agreed.")
    }

    @Test func removesEnglishFillers() {
        let clean = { TextCleaner.clean($0, language: "en", removeFillers: true) }
        #expect(clean("Um, so we should ship it.") == "So we should ship it.")
        #expect(clean("I um think it works.") == "I think it works.")
        #expect(clean("We should ship it, uh.") == "We should ship it.")
        #expect(clean("Done. Uh, next one.") == "Done. Next one.")
        #expect(clean("Hmm.") == "")
        #expect(clean("Umbrella and uh-huh stay.") == "Umbrella and uh-huh stay.")
    }

    @Test func keepsFillerLookalikesInOtherLanguages() {
        #expect(TextCleaner.clean("Tenho um carro.", language: "pt", removeFillers: true) == "Tenho um carro.")
        #expect(TextCleaner.clean("Um, ok.", language: "en", removeFillers: false) == "Um, ok.")
    }

    @Test func addsTrailingSpaceExceptInUnspacedScripts() {
        #expect(TextCleaner.forTyping("Hello.", language: "en") == "Hello. ")
        #expect(TextCleaner.forTyping("你好。", language: "zh") == "你好。")
    }
}

struct LiveTextTests {
    @Test func editsOnlyFromWhereTextDiffers() {
        #expect(LiveText.edit(from: "", to: "Hi Sam") == (0, "Hi Sam"))
        #expect(LiveText.edit(from: "Hi Sam", to: "Hi Sam, can we") == (0, ", can we"))
        #expect(LiveText.edit(from: "Hi Sam, can", to: "Hi Sam, could") == (2, "ould"))
        #expect(LiveText.edit(from: "Hi Sam ", to: "") == (7, ""))
        #expect(LiveText.edit(from: "Café 👋", to: "Café 👋 ok") == (0, " ok"), "Counts characters, as Backspace does")
        #expect(LiveText.edit(from: "👋👋", to: "👋") == (1, ""))
    }

    @Test func typesOnlyWordsTwoPassesAgreeOn() {
        #expect(LiveText.agreement("", "Hi Sam") == "")
        #expect(LiveText.agreement("Hi Sam, can", "Hi Sam, can we move") == "Hi Sam, can")
        #expect(LiveText.agreement("Hi Sam, can we", "Hi Sam, could we") == "Hi Sam,")
        #expect(LiveText.agreement("hi", "Hi") == "")
    }

    @Test func showsAllButTheLastWordUntilPassesAgree() {
        #expect(LiveText.stable(previous: "", current: "Hi Sam, can") == "Hi Sam,")
        #expect(LiveText.stable(previous: "Hi Sam, can", current: "Hi Sam, can") == "Hi Sam, can")
        #expect(LiveText.stable(previous: "Hi Sam", current: "Hi Sam, can we move") == "Hi Sam, can we")
        #expect(LiveText.stable(previous: "", current: "Hello") == "")
    }

    @Test func joinsWithoutStraySpaces() {
        #expect(LiveText.joined("", " Hello ", "world.") == "Hello world.")
        #expect(LiveText.joined("Done.", "") == "Done.")
    }
}

struct SpeechGateTests {
    @Test func needsSpeechLevelAndLength() {
        let rate = SpeechGate.sampleRate
        let tone = (0..<rate).map { Float(sin(Double($0) * 0.1) * 0.1) }
        #expect(SpeechGate.hasSpeech(tone))
        #expect(!SpeechGate.hasSpeech([Float](repeating: 0.0005, count: rate)), "Room noise")
        #expect(!SpeechGate.hasSpeech(Array(tone.prefix(rate / 10))), "Too short")
    }
}

@MainActor
struct PreferencesTests {
    @Test func languageDefaultsToEnglishAndKeepsTheUsersPick() throws {
        let suite = "MeroTyperTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Preferences(defaults: defaults).language == "en")

        // Earlier builds saved "" for auto-detect.
        defaults.set("", forKey: "language")
        #expect(Preferences(defaults: defaults).language == "en")

        Preferences(defaults: defaults).language = "ne"
        #expect(Preferences(defaults: defaults).language == "ne")
    }
}

@MainActor
struct HistoryStoreTests {
    @Test func persistsNewestFirstAndCaps() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = HistoryStore(file: file)
        for index in 0...HistoryStore.limit { store.add("Line \(index)") }
        #expect(store.items.count == HistoryStore.limit)
        #expect(store.items.first?.text == "Line \(HistoryStore.limit)")

        let reloaded = HistoryStore(file: file)
        #expect(reloaded.items == store.items)
        reloaded.clear()
        #expect(HistoryStore(file: file).items.isEmpty)
    }
}
