import AppKit
import ApplicationServices
import AVFoundation
import Observation

/// Microphone hears the user. Accessibility lets the app see the dictation key and paste into other apps.
@MainActor
@Observable
final class Permissions {
    private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var accessibility = AXIsProcessTrusted()
    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?
    @ObservationIgnored private var poller: Task<Void, Never>?

    var allGranted: Bool { microphone == .authorized && accessibility }

    func requestMicrophone() async {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else if microphone != .authorized {
            openPrivacySettings("Privacy_Microphone")
        }
        refresh()
    }

    func requestAccessibility() {
        // The prompt option adds the app to the Accessibility list, so the user only flips a switch.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openPrivacySettings("Privacy_Accessibility")
        watchAccessibility()
    }

    /// macOS has no callback for Accessibility changes, so this polls until access is granted.
    func watchAccessibility() {
        guard poller == nil, !accessibility else { return }
        poller = Task {
            while !Task.isCancelled, !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
            }
            poller = nil
            refresh()
        }
    }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let trusted = AXIsProcessTrusted()
        let granted = trusted && !accessibility
        accessibility = trusted
        if granted { onAccessibilityGranted?() }
    }

    private func openPrivacySettings(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
