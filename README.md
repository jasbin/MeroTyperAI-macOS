# Mero Typer AI (macOS)

Voice typing for every Mac app. Hold a key, speak, let go: the text is typed where your cursor is. Speech is transcribed on the Mac with OpenAI's Whisper Large V3 Turbo, so audio never leaves it. The only network use is the one-time model download (about 630 MB).

## Requirements

- A Mac with Apple silicon, macOS 14 or later
- Xcode 27.2 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Run it

```sh
xcodegen generate
open MeroTyperAI.xcodeproj
```

`project.yml` is the source of truth for the Xcode project. Edit it, not the `.xcodeproj`.

On first launch the Mero Typer window asks for three things:

1. **Microphone.** The app listens only while the dictation key is down.
2. **Accessibility.** Lets the app see the dictation key in other apps and paste the text. Turn on Mero Typer in the list that opens. If you rebuild with a different signing certificate, macOS keeps the old switch on but stops trusting the app. Remove Mero Typer from the list with the minus button, then add it again.
3. **Speech model.** It downloads, then loads once to compile for the Neural Engine. That first load takes about 2 minutes. Later launches load in about 1.5 seconds.

The app lives in the menu bar. It shows in the Dock only while its window is open.

## Use it

- **Hold fn** (or the key chosen in Settings) and speak. Let go to type.
- **Double-tap** the key for hands-free. Press it once more to finish. Recording stops by itself after 10 minutes.
- **Esc** cancels. Pressing another key while holding the dictation key also cancels, so shortcuts like right ⌘C still work.
- If the emoji picker opens when you press fn, set System Settings › Keyboard › "Press 🌐 key to" to "Do Nothing", or pick another key in Settings.
- In password fields, macOS blocks typed input. The text is copied instead, so you can paste it with ⌘V.

Settings has the dictation key, microphone, language (English by default), vocabulary hints, filler-word removal, sounds, history, and open at login.

## Test it

```sh
# Logic tests
xcodebuild test -scheme MeroTyperAI -destination 'platform=macOS,arch=arm64'

# Whisper on a real spoken sentence. Needs the model already downloaded by the app.
TEST_RUNNER_MERO_E2E=1 xcodebuild test -scheme MeroTyperAI -destination 'platform=macOS,arch=arm64' \
  -only-testing:MeroTyperAITests/TranscriberIntegrationTests
```

The fixture was made with `say -v Samantha` and `afconvert -f WAVE -d LEI16@16000 -c 1`. On an Apple silicon Mac, a 5-second sentence transcribes in about 0.7 seconds.

`scripts/make_app_icon.sh` redraws the app icon.

## How it works

1. **Key.** `HotkeyMonitor` is a listen-only event tap. It reads key codes only to spot the dictation key, Esc, and shortcuts. Nothing typed is stored. `HotkeyGesture` turns presses into start, lock (hands-free), finish, and cancel.
2. **Record.** Each take builds a fresh `AVAudioEngine` through WhisperKit's `AudioProcessor`, at 16 kHz mono. The floating pill (`HUDController`) never takes focus.
3. **Transcribe.** `Transcriber` keeps one WhisperKit instance loaded, so each dictation pays only for decoding. `SpeechGate` skips silence, where Whisper tends to make up phrases. Vocabulary goes in as Whisper's prompt.
4. **Clean.** `TextCleaner` removes sound tags such as `[BLANK_AUDIO]`, removes English fillers like "um", and adds a trailing space.
5. **Type.** With "Type while I speak" on (the default), `LiveSession` types while you talk, then replaces it with Whisper's text when you let go. It edits the field with Backspace and Unicode key events, without touching the clipboard.
   - On macOS 26 and later, the live text comes from `ApplePreview`, which uses Apple's on-device streaming recognizer (`SpeechTranscriber`). Words appear about half a second after you say them. A language Apple supports but hasn't installed downloads in the background the first time you use it.
   - Otherwise, or for languages Apple can't do, Whisper passes run back to back, one after each 0.3 s of new audio. Each takes about 0.5 s on the Neural Engine, because Whisper always encodes a 30 s window. They type every word but the last, which is often still being spoken. After 10 seconds, finished sentences are locked in.
   - It edits only text it typed itself. A click, a keystroke, or an app switch stops the editing, and the final text is copied instead. With the setting off, `TextInserter` pastes once at the end with ⌘V, finding the right key for Dvorak and other layouts. It marks the clipboard item as transient so clipboard managers skip it, then restores the previous clipboard 1 second later.

The model comes from [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-large-v3-v20240930_turbo_632MB) on Hugging Face. The tokenizer comes from [openai/whisper-large-v3](https://huggingface.co/openai/whisper-large-v3).

**Language.** Whisper always transcribes in the language picked in Settings or the menu bar, English by default. There's no auto-detect: Whisper mixed up similar languages, for example writing Hindi in Urdu script and Nepali in Korean.

Dictations finish in the order they were spoken. A new one can start while the last is still transcribing.

Files are in `~/Library/Application Support/MeroTyperAI`: the model (excluded from Time Machine) and `history.json` (last 200 dictations). Logs hold timings and errors only, never text or audio.

## Before shipping to other Macs

- The app can't be sandboxed (Accessibility needs that), so it ships outside the Mac App Store. Sign it with a Developer ID certificate and notarize it, which needs a paid Apple Developer account. `DEVELOPMENT_TEAM` in `project.yml` signs for this Mac only.
- Test with Bluetooth headsets. Starting the microphone switches AirPods to a lower-quality mode, so suggest the built-in microphone in Settings.
- Check that "Mero Typer" is free to use as a name.
