import AppKit
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let preferences = Preferences()
    let permissions = Permissions()
    let history = HistoryStore()
    let models: ModelStore
    let dictation: DictationController
    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private let window = MainWindow()

    init() {
        models = ModelStore(transcriber: transcriber)
        dictation = DictationController(
            transcriber: transcriber, preferences: preferences, history: history, models: models, permissions: permissions
        )
        dictation.onNeedsSetup = { [weak self] in self?.showWindow() }
    }

    var isSetUp: Bool { models.isReady && permissions.allGranted }

    var statusLine: String {
        switch models.state {
        case .downloading(let fraction): String(localized: "Downloading speech model… \(Int(fraction * 100))%")
        case .optimizing: String(localized: "Optimizing for this Mac…")
        default: isSetUp ? String(localized: "Hold \(preferences.hotkey.shortLabel) to dictate") : String(localized: "Setup needed")
        }
    }

    func launch() {
        // The test runner hosts the app. Taps, downloads and windows would get in its way.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        permissions.onAccessibilityGranted = { [weak self] in
            Logger.app.notice("Accessibility granted")
            guard let self, !dictation.startMonitoring() else { return }
            Logger.app.error("Couldn't watch the dictation key after Accessibility was granted")
        }
        Logger.app.notice("Accessibility trusted at launch: \(self.permissions.accessibility)")
        _ = dictation.startMonitoring()
        permissions.watchAccessibility()
        if models.isReady {
            // Loading takes a few seconds, so do it now instead of on the first dictation.
            Task { try? await transcriber.prepare() }
        } else {
            models.resumeIfRequested()
        }
        if !isSetUp { showWindow() }
    }

    func showWindow() {
        permissions.refresh()
        window.show(MainView(app: self))
    }
}

/// The app lives in the menu bar. While this window is open it also shows in the Dock and ⌘-Tab.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(_ content: some View) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.title = String(localized: "Mero Typer")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        // macOS 14 activation is cooperative, so without this the window can open behind the frontmost app.
        window?.orderFrontRegardless()
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
