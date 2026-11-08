import ServiceManagement
import SwiftUI
import WhisperKit

struct SettingsView: View {
    let app: AppModel
    @Bindable var preferences: Preferences
    @State private var microphones: [String] = []
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var modelBytes: Int64 = 0
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Dictation key", selection: $preferences.hotkey) {
                    ForEach(HotkeyKey.allCases) { Text($0.label).tag($0) }
                }
                Picker("Microphone", selection: $preferences.microphone) {
                    Text("System default").tag("")
                    ForEach(microphones, id: \.self) { Text($0).tag($0) }
                }
                Picker("Language", selection: $preferences.language) {
                    ForEach(WhisperLanguages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                Toggle(isOn: $preferences.liveTyping) {
                    Text("Type while I speak")
                    Text("Text appears as you talk and is corrected when you finish. Turn off for apps that garble it, and the text is pasted at the end instead.")
                }
                Toggle("Remove filler words like “um” (English)", isOn: $preferences.removeFillers)
                Toggle("Play sounds", isOn: $preferences.playSounds)
            }
            Section {
                TextField("Vocabulary", text: $preferences.vocabulary, prompt: Text("Mero, WhisperKit, Kathmandu"), axis: .vertical)
                    .lineLimit(2...5)
                    .labelsHidden()
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Names and terms Whisper should spell your way. Separate them with commas.")
            }
            Section {
                Toggle("Keep history", isOn: $preferences.keepHistory)
                Toggle("Open at login", isOn: $openAtLogin)
            } header: {
                Text("General")
            } footer: {
                Text("History stays on this Mac. Turning it off stops saving new dictations.")
            }
            Section("Speech model") {
                LabeledContent("Model", value: "Whisper Large V3 Turbo")
                LabeledContent("On disk", value: modelBytes.formatted(.byteCount(style: .file)))
                Button("Delete Model…", role: .destructive) { confirmDelete = true }
                    .disabled(!app.models.isReady)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: preferences.hotkey) { app.dictation.hotkeyChanged() }
        .onChange(of: app.models.state) { refresh() }
        .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
        .confirmationDialog("Delete the speech model?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await app.models.delete() } }
        } message: {
            Text("Dictation stops working until you download it again (about 630 MB).")
        }
    }

    private func refresh() {
        var names = AudioProcessor.getAudioDevices().map(\.name)
        // Keep a saved microphone that's unplugged right now, so the picker still shows it.
        if !preferences.microphone.isEmpty, !names.contains(preferences.microphone) { names.append(preferences.microphone) }
        microphones = names
        modelBytes = AppPaths.size(of: SpeechModel.root)
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct HistoryView: View {
    let history: HistoryStore
    @State private var confirmClear = false

    var body: some View {
        if history.items.isEmpty {
            ContentUnavailableView("No Dictations Yet", systemImage: "text.bubble", description: Text("What you dictate shows up here."))
        } else {
            VStack(spacing: 0) {
                List(history.items) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text).textSelection(.enabled)
                            Text(item.date, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { TextInserter.copy(item.text) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Copy")
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Copy") { TextInserter.copy(item.text) }
                        Button("Delete", role: .destructive) { history.remove(item) }
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear History…") { confirmClear = true }
                }
                .padding(12)
            }
            .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
                Button("Clear History", role: .destructive) { history.clear() }
            }
        }
    }
}

