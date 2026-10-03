// ======================================================================
// OpenShortcut.swift — opening SpaceKeeper from the keyboard
// ======================================================================
// Two parts:
//   1. ModifierTapMonitor — notices a quick tap of Control-Option on their
//      own. (The main ⌃⌥S shortcut is in GlobalHotKey.swift.)
//   2. QuickPanelController — the floating panel those shortcuts open.
//
// Why a separate floating panel? The normal menu bar panel (MenuBarExtra in
// SpaceKeeperApp.swift) closes the instant SpaceKeeper isn't the active
// app, and macOS won't let an app make itself active from a shortcut. So
// the shortcuts open this panel instead, which shows the SAME content
// (MenuPanelView) but can take typing without becoming the active app.
//
// Connected in AppModel.start(): both shortcuts call quickPanel.toggle().
// ======================================================================

import AppKit
import CGSPrivate
import SwiftUI

// How the tap is detected: an "event tap" lets us see (but not change)
// keyboard events system-wide. When Control and Option are both down we
// "arm"; if they are released within 1 second with no other key pressed,
// no extra modifier added and no desktop switch, it counts as a tap.
// The extra checks stop shortcuts like ⌃⌥1 (Switch to Desktop 11) from
// opening the panel by accident.
/// Detects a tap of Control-Option on its own (press both, release, no other
/// key in between) anywhere in macOS, and calls `onTap`.
///
/// A modifier-only shortcut can't be registered as a normal hotkey, so this
/// listens to keyboard events with a listen-only event tap (it never blocks or
/// changes keys). It uses the Accessibility permission SpaceKeeper already has.
/// The tap is ignored if any other key was pressed, another modifier joined
/// in, or the desktop changed — so ⌃⌥1…⌃⌥6 (Switch to Desktop 11–16) and other
/// Control-Option shortcuts don't open the panel.
final class ModifierTapMonitor {
    var onTap: () -> Void = {}

    /// For Diagnostics.
    private(set) var status = "off"
    private(set) var lastSeen = "never"

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var armedAt: Date?
    private var spaceWhenArmed: UInt64 = 0
    private var interrupted = false

    private static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    private static let wanted: CGEventFlags = [.maskControl, .maskAlternate]
    private static let maxTapDuration: TimeInterval = 1.0

    // Creates the event tap. The C-style `callback` can't capture variables,
    // so we pass `self` in through `userInfo` and get it back inside.
    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                let monitor = Unmanaged<ModifierTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                let flags = event.flags
                MainActor.assumeIsolated { monitor.handle(type: type, flags: flags) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status = "couldn't start — needs Accessibility (or Input Monitoring) permission"
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        status = "listening"
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        armedAt = nil
        status = "off"
    }

    private func handle(type: CGEventType, flags rawFlags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it's ever slow to respond; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        case .keyDown:
            interrupted = true
            return
        case .flagsChanged:
            break
        default:
            return
        }

        let flags = rawFlags.intersection(Self.relevant)
        if flags == Self.wanted {
            if armedAt == nil {
                armedAt = .now
                interrupted = false
                spaceWhenArmed = CGSGetActiveSpace(CGSMainConnectionID())
            }
        } else if flags.isEmpty {
            guard let started = armedAt else { return }
            armedAt = nil
            guard !interrupted, Date.now.timeIntervalSince(started) < Self.maxTapDuration else { return }
            let space = spaceWhenArmed
            // Desktop-switch shortcuts are swallowed by macOS before apps see the
            // key, so also check that no switch happened during the tap.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, CGSGetActiveSpace(CGSMainConnectionID()) == space else { return }
                self.lastSeen = Date.now.formatted(date: .omitted, time: .standard)
                self.onTap()
            }
        } else if !Self.wanted.contains(flags) {
            interrupted = true // Shift or Command joined in
        }
    }
}

// A borderless panel normally can't receive typing; this override allows
// it, so you can rename a desktop straight after opening the quick panel.
/// A panel that can take keyboard focus without activating the app.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Creates the floating panel once, then shows/hides it. It positions
// itself under the menu bar icon and closes on: the shortcut again,
// Escape, or a click anywhere outside it.
/// The ⌃⌥ panel: the same content as the menu bar panel, in a floating window
/// under the menu bar icon. A menu bar extra closes as soon as another app is
/// active, and macOS won't let SpaceKeeper make itself active from a keyboard
/// shortcut, so this uses a non-activating panel instead. It still takes typing
/// (so you can rename straight away) and closes on ⌃⌥, Escape or a click elsewhere.
final class QuickPanelController {
    private let model: AppModel
    private var panel: KeyablePanel?
    private var anchorTop: CGFloat = 0
    private var anchorRight: CGFloat = 0
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?

    /// For Diagnostics.
    private(set) var lastResult = "not tried"

    init(model: AppModel) {
        self.model = model
    }

    var isShown: Bool { panel?.isVisible == true }

    func toggle() {
        isShown ? close() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Anchor under the menu bar icon (or the top-right of the screen).
        if let button = Self.statusButton(), let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            anchorTop = frame.minY - 6
            anchorRight = frame.maxX + 12
        } else if let screen = NSScreen.main {
            anchorTop = screen.visibleFrame.maxY - 6
            anchorRight = screen.visibleFrame.maxX - 12
        }
        reposition()

        panel.makeKeyAndOrderFront(nil)
        lastResult = "shown"
        A11y.announce("SpaceKeeper open. Press Escape to close.")

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.panel?.isKeyWindow == true else { return event }
            MainActor.assumeIsolated { self.close() }
            return nil
        }
    }

    func close() {
        panel?.orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }

    // IMPORTANT: the panel is a FIXED size. An earlier version let SwiftUI
    // resize the window to fit its content while we also moved it on every
    // resize — each move triggered another resize, forever, and the app
    // crashed. A fixed size avoids that loop entirely.
    /// Fixed panel size. Letting SwiftUI resize the window to fit its content
    /// caused a layout feedback loop (and a crash), so the window stays one size
    /// and the content sits at the top of it; the transparent area below lets
    /// clicks pass through.
    private static let panelWidth: CGFloat = 360

    private func panelHeight() -> CGFloat {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        return min(visible - 20, 900)
    }

    private func makePanel() -> KeyablePanel {
        let height = panelHeight()
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the content draws its own shadow; the window is mostly transparent
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.setAccessibilityTitle("SpaceKeeper")

        let content = MenuPanelView()
            .environment(model)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .clipShape(.rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .frame(width: Self.panelWidth, height: height, alignment: .top)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [] // never let SwiftUI resize the window
        host.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: height)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func reposition() {
        guard let panel else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: anchorRight - size.width, y: anchorTop - size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchorRight - 1, y: anchorTop)) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY, origin.y)
        }
        panel.setFrameOrigin(origin)
    }

    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = find(in: subview) { return button }
        }
        return nil
    }
}
