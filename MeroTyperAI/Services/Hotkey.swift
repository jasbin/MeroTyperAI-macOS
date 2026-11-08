import CoreGraphics
import Foundation

/// A modifier key the user holds to dictate. Modifiers alone type nothing, so holding one is safe in any app.
enum HotkeyKey: String, CaseIterable, Identifiable, Sendable {
    case fn, rightCommand, rightOption, rightControl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: String(localized: "Fn (🌐)")
        case .rightCommand: String(localized: "Right ⌘ Command")
        case .rightOption: String(localized: "Right ⌥ Option")
        case .rightControl: String(localized: "Right ⌃ Control")
        }
    }

    var shortLabel: String {
        switch self {
        case .fn: "fn"
        case .rightCommand: String(localized: "right ⌘")
        case .rightOption: String(localized: "right ⌥")
        case .rightControl: String(localized: "right ⌃")
        }
    }

    fileprivate var keyCodes: Set<Int64> {
        switch self {
        case .fn: [63, 179]
        case .rightCommand: [54]
        case .rightOption: [61]
        case .rightControl: [62]
        }
    }

    /// Device-specific bits from IOKit's NX_DEVICER*KEYMASK, which tell the right key from the left one.
    fileprivate var flag: CGEventFlags {
        switch self {
        case .fn: .maskSecondaryFn
        case .rightCommand: CGEventFlags(rawValue: 0x10)
        case .rightOption: CGEventFlags(rawValue: 0x40)
        case .rightControl: CGEventFlags(rawValue: 0x2000)
        }
    }
}

/// Turns presses of the dictation key into intents. Hold to talk, double-tap for hands-free, Esc to cancel.
struct HotkeyGesture: Equatable {
    enum Phase: Equatable {
        case idle
        case holding(since: TimeInterval)
        case awaitingSecondTap(until: TimeInterval)
        case handsFree
    }

    enum Action: Equatable {
        case start, lock, finish, cancel
    }

    /// A press shorter than this is a tap, not push-to-talk.
    static let tapLimit: TimeInterval = 0.3
    static let doubleTapWindow: TimeInterval = 0.35

    private(set) var phase = Phase.idle

    /// Recording starts on the first press, so a double-tap doesn't lose its opening words.
    mutating func press(at time: TimeInterval) -> Action? {
        switch phase {
        case .idle:
            phase = .holding(since: time)
            return .start
        case .awaitingSecondTap:
            phase = .handsFree
            return .lock
        case .handsFree:
            phase = .idle
            return .finish
        case .holding:
            return nil
        }
    }

    mutating func release(at time: TimeInterval) -> Action? {
        guard case .holding(let since) = phase else { return nil }
        if time - since < Self.tapLimit {
            phase = .awaitingSecondTap(until: time + Self.doubleTapWindow)
            return nil
        }
        phase = .idle
        return .finish
    }

    /// Call before every event and when the double-tap window closes. A lone tap is discarded.
    mutating func expire(at time: TimeInterval) -> Action? {
        guard case .awaitingSecondTap(let until) = phase, time >= until else { return nil }
        phase = .idle
        return .cancel
    }

    /// Another key during push-to-talk means the modifier was part of a shortcut, like ⌘C.
    mutating func interrupt() -> Action? {
        switch phase {
        case .holding, .awaitingSecondTap:
            phase = .idle
            return .cancel
        case .idle, .handsFree:
            return nil
        }
    }

    mutating func escape() -> Action? {
        guard phase != .idle else { return nil }
        phase = .idle
        return .cancel
    }

    mutating func reset() {
        phase = .idle
    }
}

/// Watches the dictation key system-wide. Needs Accessibility access. Key codes are read only to spot
/// the dictation key, Esc, and shortcuts. Nothing typed is stored.
@MainActor
final class HotkeyMonitor {
    /// `click` and `otherKey` mean the user may have moved the cursor.
    enum Event { case down, up, otherKey, escape, click }

    var key: HotkeyKey = .fn {
        didSet { isDown = false }
    }
    var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    /// Without Accessibility the tap may still open, but it gets modifier keys only, not Esc or shortcuts.
    /// Call again after access is granted to get a full tap.
    func start() -> Bool {
        stop()
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context, event.getIntegerValueField(.eventSourceUserData) != TextInserter.syntheticMarker else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                // The tap's run loop source is on the main run loop.
                MainActor.assumeIsolated { monitor.handle(type, keyCode: keyCode, flags: flags) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        isDown = false
    }

    private func handle(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged where key.keyCodes.contains(keyCode):
            let down = flags.contains(key.flag)
            guard down != isDown else { return }
            isDown = down
            onEvent?(down ? .down : .up)
        case .keyDown:
            if keyCode == 53 {
                onEvent?(.escape)
            } else {
                onEvent?(.otherKey)
            }
        case .leftMouseDown, .rightMouseDown:
            onEvent?(.click)
        default:
            break
        }
    }
}
