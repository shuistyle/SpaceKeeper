// ======================================================================
// FnShortcut.swift — the one-handed fn-S shortcut that opens SpaceKeeper
// ======================================================================
// macOS's standard shortcut service (used for ⌃⌥S in GlobalHotKey.swift)
// doesn't accept fn as a modifier. So this file watches the keyboard
// directly with an "event tap": when you press S while holding fn (and no
// other modifier), it opens/closes SpaceKeeper and SWALLOWS that keypress,
// so no letter "s" appears in the app you were typing in. Every other key
// passes straight through untouched.
//
// Needs the Accessibility permission SpaceKeeper already has.
// Connected in AppModel.start(): `onPress` toggles the panel. Turned on/off
// with the keyboard-shortcut setting (AppModel.openWithModifierTap).
//
// Note: keyboards without an fn key (many non-Apple ones) can still use ⌃⌥S.
// ======================================================================

import AppKit
import Carbon.HIToolbox

final class FnShortcut {
    var onPress: () -> Void = {}

    /// For the Diagnostics report.
    private(set) var status = "off"
    private(set) var pressCount = 0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowNextKeyUp = false

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let shortcut = Unmanaged<FnShortcut>.fromOpaque(userInfo).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let flags = event.flags
            let swallow = MainActor.assumeIsolated {
                shortcut.handle(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        // .defaultTap (not listen-only) so the fn-S keypress can be swallowed.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
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
        status = "listening for fn-S"
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        status = "off"
    }

    /// Returns true if the event should be swallowed.
    private func handle(type: CGEventType, keyCode: Int64, isRepeat: Bool, flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it's ever slow; turn it straight back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .keyUp:
            if keyCode == Int64(kVK_ANSI_S), swallowNextKeyUp {
                swallowNextKeyUp = false
                return true
            }
            return false
        case .keyDown:
            guard keyCode == Int64(kVK_ANSI_S),
                  flags.contains(.maskSecondaryFn),
                  flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
            else { return false }
            swallowNextKeyUp = true
            if !isRepeat {
                pressCount += 1
                onPress()
            }
            return true
        default:
            return false
        }
    }
}
