import SwiftUI

struct MainView: View {
    let app: AppModel

    var body: some View {
        TabView {
            HomeView(app: app)
                .tabItem { Label("Home", systemImage: "house") }
            HistoryView(history: app.history)
                .tabItem { Label("History", systemImage: "clock") }
            SettingsView(app: app, preferences: app.preferences)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.permissions.refresh()
        }
    }
}

struct HomeView: View {
    let app: AppModel
    @State private var scratch = ""

    private var key: String { app.preferences.hotkey.shortLabel }

    var body: some View {
        Form {
            Section("Setup") {
                SetupRow(
                    title: "Microphone",
                    detail: "Mero Typer listens only while you hold the dictation key.",
                    isDone: app.permissions.microphone == .authorized
                ) {
                    Button("Allow") { Task { await app.permissions.requestMicrophone() } }
                }
                SetupRow(
                    title: "Accessibility",
                    detail: "Lets Mero Typer notice the dictation key and type into other apps. Turn on Mero Typer in the list that opens.",
                    isDone: app.permissions.accessibility
                ) {
                    Button("Open Settings") { app.permissions.requestAccessibility() }
                }
                ModelRow(models: app.models)
            }
            Section("How to dictate") {
                Label("Hold \(key) and speak. Let go, and the text is typed where your cursor is.", systemImage: "hand.tap")
                Label("Double-tap \(key) for hands-free. Press it once more to finish.", systemImage: "lock")
                Label("Press Esc to cancel.", systemImage: "escape")
                if app.preferences.hotkey == .fn {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("If the emoji picker opens when you press fn, set “Press 🌐 key to” to “Do Nothing” in Keyboard settings.")
                            .foregroundStyle(.secondary)
                        Button("Open Keyboard Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                    }
                }
            }
            Section("Try it") {
                // In a form a title becomes a side label, so the hint goes in the prompt and the field gets the full width.
                TextField("Try it", text: $scratch, prompt: Text("Click here, then hold \(key) and talk"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(4...8)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SetupRow<Action: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let isDone: Bool
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? .green : .secondary)
                .font(.title3)
                .accessibilityLabel(isDone ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
            if !isDone { action }
        }
    }
}

private struct ModelRow: View {
    let models: ModelStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: models.isReady ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(models.isReady ? .green : .secondary)
                .font(.title3)
                .accessibilityLabel(models.isReady ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 4) {
                Text("Speech model").font(.headline)
                switch models.state {
                case .missing:
                    Text("Whisper Large V3 Turbo, about 630 MB. It runs on this Mac, so your voice never leaves it.")
                        .foregroundStyle(.secondary)
                case .downloading(let fraction):
                    ProgressView(value: fraction)
                    Text("Downloading… \(Int(fraction * 100))%").foregroundStyle(.secondary)
                case .optimizing:
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Optimizing for this Mac. The first time can take a few minutes.").foregroundStyle(.secondary)
                case .ready:
                    Text("Whisper Large V3 Turbo is ready.").foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                }
            }
            Spacer()
            switch models.state {
            case .missing: Button("Download") { models.prepare() }
            case .failed: Button("Try Again") { models.prepare() }
            default: EmptyView()
            }
        }
    }
}
