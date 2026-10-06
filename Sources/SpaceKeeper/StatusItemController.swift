// ======================================================================
// StatusItemController.swift — the SpaceKeeper icon in the menu bar
// ======================================================================
// Shows the stacked-squares icon (or an orange warning triangle when a
// pinned desktop is out of order) and, if "Show name in menu bar" is on,
// the current desktop's name.
//
//   • Left-click  → opens/closes the SpaceKeeper panel, centred at the top
//                   of the screen (QuickPanelController in OpenShortcut.swift).
//   • Right-click → a small menu: Open SpaceKeeper / Quit.
//
// Why not SwiftUI's MenuBarExtra? Its panel always drops down from the icon
// and can't be centred, and the desktop grid is too wide for that.
//
// Created by AppDelegate (SpaceKeeperApp.swift) after AppModel starts.
// It redraws itself whenever the AppModel values it shows change, using
// Swift's Observation tracking (see observe()).
// ======================================================================

import AppKit
import Observation

final class StatusItemController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        update()
        observe()
    }

    // MARK: Drawing

    private func update() {
        guard let button = item.button else { return }
        let hasAlert = !model.pinAlerts.isEmpty
        button.image = hasAlert ? Self.warningIcon : Self.normalIcon

        if model.showNameInMenuBar, let space = model.currentSpace {
            button.title = " " + model.displayName(for: space).truncated(to: 24)
        } else {
            button.title = ""
        }

        var spoken = "SpaceKeeper"
        if let space = model.currentSpace { spoken += ", current Space: \(model.displayName(for: space))" }
        if hasAlert { spoken += ", warning: pinned order changed" }
        button.setAccessibilityLabel(spoken)
        button.toolTip = "SpaceKeeper — click to show your desktops (double-tap Control)"
    }

    /// Re-runs update() whenever any AppModel value it reads changes.
    private func observe() {
        withObservationTracking {
            _ = model.pinAlerts
            _ = model.showNameInMenuBar
            _ = model.currentSpace
            _ = model.configs // names
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open SpaceKeeper", action: #selector(openPanel), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit SpaceKeeper", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = menu
            item.button?.performClick(nil) // shows the menu
            item.menu = nil                // so the next left-click opens the panel again
        } else {
            model.toggleQuickPanel()
        }
    }

    @objc private func openPanel() { model.toggleQuickPanel() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Icons

    private static let normalIcon: NSImage = {
        let image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "SpaceKeeper") ?? NSImage()
        image.isTemplate = true // adapts to light/dark menu bars
        return image
    }()

    /// Orange triangle. Its SHAPE also signals the problem, not just the colour.
    private static let warningIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                            accessibilityDescription: "Pinned desktop order changed")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}
