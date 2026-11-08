import AppKit
import SwiftUI

/// A small pill at the bottom of the screen. It never takes focus, so typing stays in the user's app.
@MainActor
final class HUDController {
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
    }

    func setContent(_ view: some View) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    func show() {
        guard !panel.isVisible else { return }
        // The screen with the pointer is the one the user is looking at.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 20))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct HUDView: View {
    let dictation: DictationController

    var body: some View {
        HStack(spacing: 8) {
            if let recording = dictation.recording {
                if dictation.isHandsFree {
                    Image(systemName: "lock.fill").font(.caption2)
                }
                LevelBars(buffer: recording.buffer)
            } else if let notice = dictation.notice {
                Text(notice).font(.callout)
            } else {
                ProgressView().controlSize(.small).tint(.white)
                Text("Transcribing").font(.callout)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        .fixedSize()
        .animation(.snappy(duration: 0.2), value: dictation.isHandsFree)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        if dictation.recording != nil { return Text("Listening") }
        if let notice = dictation.notice { return Text(notice) }
        return Text("Transcribing")
    }
}

/// Bars that follow the microphone level.
struct LevelBars: View {
    let buffer: SampleBuffer
    private static let weights: [Double] = [0.35, 0.6, 0.85, 1, 0.85, 0.6, 0.35]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let level = Self.normalized(buffer.level)
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(Self.weights.indices, id: \.self) { index in
                    let wobble = 0.75 + 0.25 * sin(time * 9 + Double(index) * 1.3)
                    Capsule().frame(width: 3, height: 4 + 16 * level * Self.weights[index] * wobble)
                }
            }
            .frame(width: 60, height: 20)
        }
    }

    /// Maps -55…-15 dBFS onto 0…1.
    static func normalized(_ rms: Float) -> Double {
        let decibels = 20 * log10(Double(max(rms, 1e-6)))
        return min(max((decibels + 55) / 40, 0), 1)
    }
}
