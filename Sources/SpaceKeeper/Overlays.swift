// ======================================================================
// Overlays.swift — text that appears ON your screen (outside the panel)
// ======================================================================
// Two features live here, both driven by AppModel:
//   1. The switch banner ("HUD", heads-up display): the big name that
//      appears briefly when you change Space. AppModel.refresh() calls
//      HUDController.show(...).
//   2. Desktop labels: a small name tag in a corner of each desktop.
//      AppModel.syncLabels() calls DesktopLabelManager.sync(...).
//
// Both are "windows" with no title bar that you can click straight
// through. Each mixes two technologies:
//   • AppKit (NSPanel) — creates and positions the window itself
//   • SwiftUI (HUDView, DesktopLabelView) — draws what's inside it
// NSHostingView is the adapter that puts SwiftUI content into an AppKit
// window.
//
// Accessibility: both adapt to Reduce Motion, Reduce Transparency,
// Increase Contrast and the text-size setting (see A11y in
// SystemBridges.swift), and are hidden from VoiceOver because AppModel
// announces the same information.
// ======================================================================

import AppKit
import SwiftUI

// A reusable recipe for an invisible, click-through, never-focused window.
// Used by both the HUD and the desktop labels below.
extension NSPanel {
    /// A transparent, click-through, never-activating panel for on-screen labels.
    static func overlay(level: NSWindow.Level, behavior: NSWindow.CollectionBehavior) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.collectionBehavior = behavior
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        // Decorative overlays: keep them out of VoiceOver's window list.
        panel.setAccessibilityElement(false)
        return panel
    }
}

// MARK: - Switch HUD

// Shows the banner, waits, fades it out, hides it. If you switch again
// before it disappears, the old timer is cancelled (hideTask) and the
// banner simply updates.
/// Briefly shows the Space's name, centred low on the screen, whenever you switch.
final class HUDController {
    private lazy var panel = NSPanel.overlay(
        level: .statusBar,
        behavior: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    )
    private var hideTask: Task<Void, Never>?

    func show(title: String, subtitle: String?, textSize: OverlayTextSize = .standard) {
        let host = NSHostingView(rootView: HUDView(
            title: title,
            subtitle: subtitle,
            points: textSize.hudPoints,
            solid: A11y.reduceTransparency || A11y.increaseContrast
        ))
        let size = host.fittingSize
        panel.contentView = host

        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        else { return }

        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.16)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            // Stay a little longer for people using VoiceOver or Reduce Motion.
            let seconds = (A11y.voiceOverRunning || A11y.reduceMotion) ? 2.0 : 1.2
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            if !A11y.reduceMotion {
                // The SDK's async overload waits for the fade to finish.
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.35
                    panel.animator().alphaValue = 0
                }
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

// What the banner looks like. `points` is the text size (from
// OverlayTextSize in Models.swift); `solid` swaps the see-through glass for
// a solid, outlined background for people who need higher contrast.
struct HUDView: View {
    let title: String
    let subtitle: String?
    var points: CGFloat = 34
    /// Solid background for Reduce Transparency / Increase Contrast.
    var solid = false

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: points, weight: .bold, design: .rounded))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: max(13, points * 0.4)))
                    .foregroundStyle(solid ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .overlayBackground(solid: solid, shape: .rect(cornerRadius: 28))
        .padding(24)
        .fixedSize()
        // The same information is announced to VoiceOver by AppModel.
        .accessibilityHidden(true)
    }
}

extension View {
    // Shared styling helper used by HUDView and DesktopLabelView.
    /// Liquid Glass normally; an opaque, bordered background when the user has
    /// Reduce Transparency or Increase Contrast turned on.
    @ViewBuilder
    func overlayBackground<S: Shape>(solid: Bool, shape: S) -> some View {
        if solid {
            background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.6), lineWidth: 1.5))
        } else {
            glassEffect(.regular, in: shape)
        }
    }
}

// MARK: - Per-desktop labels

// The trick that makes a label belong to ONE desktop: a normal window
// stays on the Space where it was first shown. So when you first visit a
// desktop, we create its label window there and macOS keeps it on that
// desktop — it even shows in that desktop's Mission Control thumbnail.
// `panels` remembers one label window per Space key.
/// Puts a small name tag on each desktop. A window that is not set to "join all
/// Spaces" belongs to the Space it was first shown on, so we create one label the
/// first time each desktop becomes visible and macOS keeps it there. Because the
/// label lives on that desktop, it also appears in that desktop's thumbnail in
/// Mission Control.
final class DesktopLabelManager {
    private var panels: [String: NSPanel] = [:]

    // Called after every refresh and every setting/name change:
    //   • closes labels for Spaces that no longer exist
    //   • updates text, size, corner and layer of existing labels
    //   • creates a label for any visible desktop that doesn't have one yet
    func sync(snapshot: SpaceSnapshot, settings: AppSettings, name: (SpaceInfo) -> String) {
        guard settings.showDesktopLabels else {
            removeAll()
            return
        }

        let desktops = snapshot.allSpaces.filter { $0.kind == .desktop }
        let live = Dictionary(desktops.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        // Close labels for Spaces that no longer exist.
        for key in Array(panels.keys) where live[key] == nil {
            panels.removeValue(forKey: key)?.close()
        }

        // Refresh existing labels (name, corner, layer, opacity).
        for (key, panel) in panels {
            if let space = live[key] {
                configure(panel, for: space, settings: settings, name: name(space))
            }
        }

        // Create labels for whichever desktop is visible on each display right now.
        for display in snapshot.displays {
            guard let current = display.currentSpace,
                  current.kind == .desktop,
                  panels[current.key] == nil
            else { continue }

            let panel = NSPanel.overlay(level: .floating, behavior: [.stationary, .ignoresCycle, .fullScreenNone])
            configure(panel, for: current, settings: settings, name: name(current))
            panel.orderFrontRegardless()
            panels[current.key] = panel
        }
    }

    func removeAll() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    private func configure(_ panel: NSPanel, for space: SpaceInfo, settings: AppSettings, name: String) {
        panel.level = switch settings.labelLayer {
        case .desktop: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case .floating: .floating
        }

        let host = NSHostingView(rootView: DesktopLabelView(
            name: name,
            // With Increase Contrast, never let the label fade into the wallpaper.
            opacity: A11y.increaseContrast ? max(settings.labelOpacity, 0.95) : settings.labelOpacity,
            points: settings.overlayTextSize.labelPoints,
            solid: A11y.reduceTransparency || A11y.increaseContrast
        ))
        let size = host.fittingSize
        panel.contentView = host

        guard let screen = SpaceReader.screen(forDisplayID: space.displayID) else { return }
        let frame = screen.visibleFrame
        let x = settings.labelCorner.isLeft ? frame.minX : frame.maxX - size.width
        let y = settings.labelCorner.isBottom ? frame.minY : frame.maxY - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

// What a desktop label looks like (a rounded "capsule" with the name).
struct DesktopLabelView: View {
    let name: String
    let opacity: Double
    var points: CGFloat = 20
    var solid = false

    var body: some View {
        Text(name)
            .font(.system(size: points, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlayBackground(solid: solid, shape: .capsule)
            .opacity(opacity)
            .padding(14)
            .fixedSize()
            .accessibilityHidden(true) // decorative; the panel and menu bar carry the name
    }
}
