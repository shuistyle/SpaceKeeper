// ======================================================================
// OpenShortcut.swift — opening SpaceKeeper from the keyboard
// ======================================================================
// QuickPanelController — the floating panel that the keyboard shortcuts
// (fn-S in FnShortcut.swift, ⌃⌥S in GlobalHotKey.swift) and the menu bar
// icon open.
//
// (Earlier versions also opened it with a tap of Control-Option on its own.
// That was removed because Parallels Desktop uses Control-Option to release
// the mouse and keyboard from Windows, so it opened SpaceKeeper by accident.)
//
// The panel is a floating window centred at the top of the screen (like
// Mission Control's desktop strip), opened by clicking the menu bar icon
// (StatusItemController) or the shortcuts. It shows MenuPanelView. It
// can take typing without making SpaceKeeper the active app.
//
// Connected in AppModel.start(): both shortcuts call quickPanel.toggle().
// ======================================================================

import AppKit
import SwiftUI

// A borderless panel normally can't receive typing; this override allows
// it, so you can rename a desktop straight after opening the quick panel.
/// A panel that can take keyboard focus without activating the app.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Creates the floating panel once, then shows/hides it. It positions
// itself under the menu bar icon and closes on: the shortcut again,
// Escape, or a click anywhere outside it.
/// The quick panel: the same content as the menu bar panel, in a floating window
/// under the menu bar icon. A menu bar extra closes as soon as another app is
/// active, and macOS won't let SpaceKeeper make itself active from a keyboard
/// shortcut, so this uses a non-activating panel instead. It still takes typing
/// (so you can rename straight away) and closes on the shortcut again, Escape or a click elsewhere.
final class QuickPanelController {
    private let model: AppModel
    private var panel: KeyablePanel?
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

        // Centre at the top of the screen that has the menu bar icon
        // (or the main screen): the window spans the screen's width and the
        // panel sits centred at its top; the transparent rest lets clicks through.
        let screen = Self.statusButton()?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            let height = min(visible.height - 12, 1100)
            panel.setFrame(NSRect(x: visible.minX, y: visible.maxY - height - 6,
                                  width: visible.width, height: height), display: true)
        }
        model.panelDidAppear()
        model.quickPanelDidOpen()

        panel.makeKeyAndOrderFront(nil)
        lastResult = "shown"
        A11y.announce("SpaceKeeper open. Press Escape to close.")

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.panel?.isKeyWindow == true else { return event }
            // While renaming, Esc cancels the rename instead of closing the panel.
            if self.panel?.firstResponder is NSTextView { return event }
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
    /// Starting width; show() resizes the window to the screen's width.
    private static let panelWidth: CGFloat = 900

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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [] // never let SwiftUI resize the window
        host.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: height)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
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
