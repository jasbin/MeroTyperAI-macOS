import AppKit
import SwiftUI

@main
struct MeroTyperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: delegate.app)
        } label: {
            Image(systemName: delegate.app.dictation.isRecording ? "mic.fill" : "waveform")
                .accessibilityLabel("Mero Typer")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.launch()
    }

    /// Opening the app again from Finder or Spotlight shows its window, since it has no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        app.showWindow()
        return true
    }
}

struct MenuContent: View {
    let app: AppModel

    var body: some View {
        Text(app.statusLine)
        Divider()
        if !app.history.items.isEmpty {
            Section("Recent, click to copy") {
                ForEach(app.history.items.prefix(5)) { item in
                    Button(item.text.count > 48 ? item.text.prefix(48) + "…" : item.text) {
                        TextInserter.copy(item.text)
                    }
                }
            }
            Divider()
        }
        Picker("Language", selection: Bindable(app.preferences).language) {
            ForEach(WhisperLanguages.all, id: \.code) { Text($0.name).tag($0.code) }
        }
        Divider()
        Button("Open Mero Typer…") { app.showWindow() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Mero Typer") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
