// ======================================================================
// DoubleTapControl.swift — open SpaceKeeper by tapping Control twice
// ======================================================================
// The one-handed shortcut (the same as the Windows version's double-tap
// Ctrl). A "tap" is Control pressed and released quickly, on its own: no
// other key, modifier or mouse click in between. So ⌃1 (Switch to Desktop
// 1), ⌃-click (right-click), holding Control while scrolling and so on
// never count. Two taps within the double-click time (System Settings ›
// Mouse/Trackpad) open or close the panel.
//
// HOW: an "event tap" lets SpaceKeeper SEE keyboard events system-wide.
// This one is listen-only — it can't block or change any key — so typing
// and macOS's own shortcuts are never affected. (macOS's standard shortcut
// service, used for ⌃⌥S in GlobalHotKey.swift, can't do "tap a key twice".)
//
// While Parallels Desktop (or another Parallels window) is in front, double
// taps are ignored, so double-tapping Ctrl for the WINDOWS SpaceKeeper
// doesn't open the Mac one too.
//
// Needs the Accessibility permission SpaceKeeper already has.
// Connected in AppModel.start(): `onPress` toggles the panel. Turned on/off
// with the keyboard-shortcut setting (AppModel.openWithModifierTap).
// ======================================================================

import AppKit

final class DoubleTapControl {
    var onPress: () -> Void = {}

    /// For the Diagnostics report.
    private(set) var status = "off"
    private(set) var pressCount = 0

    /// A tap must be shorter than this, so holding Control doesn't count.
    private let maxTapDuration: TimeInterval = 0.35

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // State of the current tap sequence.
    private var controlDown = false
    private var cleanTap = false            // nothing else happened while Control was down
    private var controlDownAt = Date.distantPast
    private var lastTapAt: Date?            // when the previous clean tap finished

    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                let monitor = Unmanaged<DoubleTapControl>.fromOpaque(userInfo).takeUnretainedValue()
                let flags = event.flags
                MainActor.assumeIsolated { monitor.handle(type: type, flags: flags) }
            }
            return Unmanaged.passUnretained(event) // listen-only: always pass the event on
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status = "couldn't start — needs Accessibility permission"
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        status = "listening for a double tap of Control"
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        reset()
        status = "off"
    }

    private func reset() {
        controlDown = false
        cleanTap = false
        lastTapAt = nil
    }

    private func handle(type: CGEventType, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it's ever slow; turn it straight back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reset()

        case .flagsChanged:
            let others = flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn])
            let controlNow = flags.contains(.maskControl)

            if controlNow && !controlDown {
                // Control just went down.
                controlDown = true
                cleanTap = others.isEmpty
                controlDownAt = .now
            } else if controlNow && controlDown {
                // Another modifier changed while Control is held → not a tap.
                cleanTap = false
                lastTapAt = nil
            } else if !controlNow && controlDown {
                // Control just came up.
                controlDown = false
                let quick = Date.now.timeIntervalSince(controlDownAt) <= maxTapDuration
                guard cleanTap, quick, others.isEmpty else { lastTapAt = nil; return }
                finishTap()
            } else if !others.isEmpty {
                lastTapAt = nil // another modifier on its own breaks the sequence
            }

        default:
            // Any key or mouse click: part of a shortcut or ordinary typing.
            if controlDown { cleanTap = false }
            lastTapAt = nil
        }
    }

    private func finishTap() {
        if let last = lastTapAt, Date.now.timeIntervalSince(last) <= NSEvent.doubleClickInterval {
            lastTapAt = nil // a third tap starts afresh
            if Self.parallelsIsInFront { return }
            pressCount += 1
            onPress()
        } else {
            lastTapAt = .now // first tap; wait for the second
        }
    }

    /// True while Parallels Desktop or one of its windows is the active app.
    private static var parallelsIsInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.parallels") == true
    }
}
