// ======================================================================
// SystemBridges.swift — small helpers that talk to macOS
// ======================================================================
// Each `enum` below is just a named group of related functions (we never
// create one; we call e.g. `SpaceSwitcher.switchTo(desktop: 3)`).
//
//   DockPreferences  "Keep Spaces in a fixed order"   ← AppModel
//   SpaceSwitcher    jumping to a desktop, turning on  ← AppModel
//                    the "Switch to Desktop" shortcuts
//   Diagnostics      who signed the app (for the report) ← AppModel
//   SystemUI         opening Mission Control / System Settings ← views
//   A11y             the user's accessibility settings and
//                    VoiceOver announcements          ← used everywhere
// ======================================================================

import AppKit
import ApplicationServices
import Security
import CGSPrivate

// MARK: - Dock preference: "Automatically rearrange Spaces based on most recent use"

// The Dock keeps its settings in a preferences "domain" called
// com.apple.dock. The "mru-spaces" setting (most-recently-used Spaces) is
// the System Settings switch "Automatically rearrange Spaces based on most
// recent use". We read it directly, and change it with the `defaults`
// command, then restart the Dock so it takes effect.
enum DockPreferences {
    private static var domain: CFString { "com.apple.dock" as CFString }

    /// macOS default is `true` when the key is absent.
    static var autoRearrangeEnabled: Bool {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("mru-spaces" as CFString, domain) as? Bool) ?? true
    }

    /// Writes the same setting as System Settings › Desktop & Dock, then restarts the Dock
    /// so it takes effect. Windows and Spaces are preserved; the Dock reappears in ~1s.
    static func setAutoRearrange(_ enabled: Bool) throws {
        try run("/usr/bin/defaults", ["write", "com.apple.dock", "mru-spaces", "-bool", enabled ? "true" : "false"])
        try run("/usr/bin/killall", ["Dock"])
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandError(command: ([path] + arguments).joined(separator: " "), status: process.terminationStatus)
        }
    }

    struct CommandError: LocalizedError {
        let command: String
        let status: Int32
        var errorDescription: String? { "“\(command)” failed (exit \(status))." }
    }
}

// MARK: - Switching Spaces

// How switching works:
//   1. shortcutState(forDesktop:) asks the window server whether the
//      "Switch to Desktop N" shortcut is on, and which keys it uses.
//      (IDs 118–133 are macOS's built-in numbers for Desktops 1–16.)
//   2. switchTo(desktop:) "presses" those keys using CGEvent (a simulated
//      keypress). This needs the Accessibility permission.
//   3. enableDesktopShortcuts(upTo:) turns those shortcuts on, exactly as
//      ticking them in System Settings would, if they are off.
/// macOS has no public "go to Space" call, so SpaceKeeper presses your
/// "Switch to Desktop N" keyboard shortcut for you (System Settings ›
/// Keyboard › Keyboard Shortcuts › Mission Control). Needs Accessibility.
enum SpaceSwitcher {
    struct Shortcut: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        let character: String

        var symbol: String {
            var s = ""
            if flags.contains(.maskControl) { s += "⌃" }
            if flags.contains(.maskAlternate) { s += "⌥" }
            if flags.contains(.maskShift) { s += "⇧" }
            if flags.contains(.maskCommand) { s += "⌘" }
            return s + character.uppercased()
        }
    }

    enum ShortcutState: Equatable {
        case on(Shortcut)
        case off

        var shortcut: Shortcut? {
            if case .on(let s) = self { return s }
            return nil
        }

        var summary: String {
            switch self {
            case .on(let s): "\(s.symbol) (on)"
            case .off: "off"
            }
        }
    }

    /// macOS offers "Switch to Desktop N" shortcuts for desktops 1–16.
    static let maxDesktop = 16

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Live state of "Switch to Desktop N" (symbolic hotkey IDs 118…133),
    /// read from the window server, so it's always what macOS will actually do.
    static func shortcutState(forDesktop number: Int) -> ShortcutState {
        guard (1...maxDesktop).contains(number) else { return .off }
        let id = UInt32(117 + number)
        guard SKIsSymbolicHotKeyEnabled(id) else { return .off }

        var character: UInt16 = 0, keyCode: UInt16 = 0, modifiers: UInt64 = 0
        guard SKGetSymbolicHotKey(id, &character, &keyCode, &modifiers), keyCode != 0xFFFF else { return .off }

        let label: String
        if character > 0, character < 0xFFFF, let scalar = UnicodeScalar(UInt32(character)) {
            label = String(Character(scalar))
        } else {
            label = "key \(keyCode)"
        }
        return .on(Shortcut(keyCode: CGKeyCode(keyCode), flags: CGEventFlags(rawValue: modifiers), character: label))
    }

    /// Turns on "Switch to Desktop N" for desktops 1…count (max 16), exactly as
    /// ticking them in System Settings would. Shortcuts that are already on are
    /// left alone. Desktops 1–10 get ⌃1…⌃0; 11–16 get ⌃⌥1…⌃⌥6.
    /// Returns how many were turned on.
    @discardableResult
    static func enableDesktopShortcuts(upTo count: Int) -> Int {
        let domain = "com.apple.symbolichotkeys" as CFString
        let key = "AppleSymbolicHotKeys" as CFString
        CFPreferencesAppSynchronize(domain)
        var saved = (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
        var changed = 0

        for number in 1...min(max(count, 1), maxDesktop) where shortcutState(forDesktop: number) == .off {
            let digit = number <= 10 ? number % 10 : number - 10
            guard let keyCode = digitKeyCodes[digit] else { continue }
            var flags = CGEventFlags.maskControl
            if number > 10 { flags.insert(.maskAlternate) }
            let character = UInt16(48 + digit) // ASCII "0"…"9"
            let id = UInt32(117 + number)

            guard SKSetSymbolicHotKey(id, character, keyCode, flags.rawValue, true) else { continue }
            // Save it the same way System Settings does, so it survives restarts.
            saved[String(id)] = [
                "enabled": true,
                "value": [
                    "parameters": [Int(character), Int(keyCode), Int(flags.rawValue)],
                    "type": "standard",
                ],
            ] as [String: Any]
            changed += 1
        }

        if changed > 0 {
            CFPreferencesSetAppValue(key, saved as CFDictionary, domain)
            CFPreferencesAppSynchronize(domain)
        }
        return changed
    }

    /// Key codes for the top-row digits 0–9.
    private static let digitKeyCodes: [Int: CGKeyCode] = [
        1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25, 0: 29,
    ]

    /// Presses the desktop's shortcut. Returns the keys pressed, or an error message.
    static func switchTo(desktop number: Int) -> Result<Shortcut, SwitchError> {
        guard isTrusted else { return .failure(.notTrusted) }
        guard number <= maxDesktop else { return .failure(.beyondShortcuts(number)) }
        guard let shortcut = shortcutState(forDesktop: number).shortcut else {
            return .failure(.shortcutOff(number))
        }
        post(shortcut)
        return .success(shortcut)
    }

    enum SwitchError: Error {
        case notTrusted, beyondShortcuts(Int), shortcutOff(Int)

        var message: String {
            switch self {
            case .notTrusted:
                "SpaceKeeper doesn't have Accessibility permission. See Diagnostics below."
            case .beyondShortcuts(let n):
                "macOS only has shortcuts for Desktops 1–16, so SpaceKeeper can't jump to Desktop \(n)."
            case .shortcutOff(let n):
                "macOS’s “Switch to Desktop \(n)” shortcut is off. Click “Turn On Shortcuts” above."
            }
        }
    }

    // Sends the keypress the same way a real keyboard would: modifier keys
    // down (e.g. Control), the main key down and up, then modifiers up.
    //
    // Two details stop the digit ever arriving on its own (which would type
    // "3" if macOS didn't treat it as the shortcut):
    //   • a PRIVATE event source, so the keys you're physically holding (or
    //     have just let go of) can't mix into these events' modifier state;
    //   • a short pause between keys, so the window server has registered
    //     Control as held down before the digit arrives.
    // The caller also holds the keyboard with KeystrokeCatcher, so even a
    // keystroke macOS ignores can't reach the app you were using.
    /// Posts the full key sequence (modifier down, key down/up, modifier up).
    private static func post(_ shortcut: Shortcut) {
        let source = CGEventSource(stateID: .privateState)
        let modifierKeys: [(flag: CGEventFlags, key: CGKeyCode)] = [
            (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55),
        ].filter { shortcut.flags.contains($0.flag) }

        var flags: CGEventFlags = []
        func send(_ key: CGKeyCode, down: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags.union(.maskNonCoalesced)
            event?.post(tap: .cghidEventTap)
            usleep(8_000) // 8 ms
        }

        for modifier in modifierKeys {
            flags.insert(modifier.flag)
            send(modifier.key, down: true)
        }
        send(shortcut.keyCode, down: true)
        send(shortcut.keyCode, down: false)
        for modifier in modifierKeys.reversed() {
            flags.remove(modifier.flag)
            send(modifier.key, down: false)
        }
    }
}

// MARK: - Keystroke catcher

// While SpaceKeeper presses a "Switch to Desktop" shortcut for you, this
// invisible 1-pixel window holds the keyboard. Normally macOS catches the
// shortcut and switches desktop. But if it doesn't (it's still finishing
// the last switch, an app such as Parallels has turned the shortcuts off,
// or macOS is ignoring them), the keystroke lands HERE and is thrown away,
// instead of typing "3" into the web page or document you were using.
//
// It's a non-activating panel, like the quick panel, so holding the
// keyboard doesn't make SpaceKeeper the active app or change the menu bar.
// It's on every desktop, so it still holds the keyboard during the switch.
/// Holds keyboard focus (and swallows every key) while SpaceKeeper presses a shortcut.
final class KeystrokeCatcher {
    static let shared = KeystrokeCatcher()

    private final class CatcherPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Accepts the keyboard and ignores everything it receives.
    private final class SwallowingView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {}
        override func keyUp(with event: NSEvent) {}
        override func flagsChanged(with event: NSEvent) {}
        override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
    }

    private lazy var panel: CatcherPanel = {
        let panel = CatcherPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.01 // effectively invisible, but still a real window that can hold the keyboard
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityElement(false)
        panel.contentView = SwallowingView()
        return panel
    }()

    /// Takes the keyboard. Returns true once it really has it.
    @discardableResult
    func hold() -> Bool {
        let corner = NSScreen.main?.frame.origin ?? .zero
        panel.setFrameOrigin(corner)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(panel.contentView)
        return isHolding
    }

    var isHolding: Bool { panel.isVisible && panel.isKeyWindow }

    /// Gives the keyboard back (to the front window on whichever desktop you're on now).
    func release() {
        panel.orderOut(nil)
    }
}

// MARK: - Diagnostics

// Information for the Diagnostics report. `signature` reveals whether the
// app is signed with a stable certificate (see build.sh) — if not, macOS
// forgets the Accessibility permission after every rebuild.
enum Diagnostics {
    /// Who signed the running app. Ad-hoc signatures change every build, which
    /// makes macOS forget the Accessibility permission.
    static var signature: String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "unknown" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return "unknown" }
        if let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first,
           let name = SecCertificateCopySubjectSummary(leaf).map({ $0 as String }) {
            return name
        }
        return "ad-hoc (permission is lost on every rebuild)"
    }

    static var appPath: String { Bundle.main.bundlePath }
}

// MARK: - Opening system UI

// Shortcuts for opening Apple's own apps and Settings pages.
enum SystemUI {
    static func openMissionControl() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    }

    static func openKeyboardShortcuts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Accessibility preferences & VoiceOver announcements

// Accessibility helpers. The first five properties read the user's
// choices in System Settings › Accessibility (Reduce Motion, Reduce
// Transparency, Increase Contrast, Differentiate Without Colour, VoiceOver).
// Overlays.swift and the views use them to adapt how things look and move.
// announce() makes VoiceOver speak a message — used for things that happen
// outside the panel, like switching Space or a pinned desktop moving.
/// The user's system-wide accessibility settings (System Settings › Accessibility),
/// and VoiceOver announcements for things that happen outside the panel.
enum A11y {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var differentiateWithoutColor: Bool { NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor }
    static var voiceOverRunning: Bool { NSWorkspace.shared.isVoiceOverEnabled }

    /// Asks VoiceOver (if running) to speak `text`.
    static func announce(_ text: String, important: Bool = false) {
        guard voiceOverRunning, !text.isEmpty else { return }
        let priority: NSAccessibilityPriorityLevel = important ? .high : .medium
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: text,
                NSAccessibility.NotificationUserInfoKey.priority: priority.rawValue,
            ]
        )
    }
}
