// ======================================================================
// MissionControl.swift — adding and removing desktops
// ======================================================================
// macOS gives apps no direct way to add or remove desktops. So this file
// does what you would do by hand: it opens Mission Control, finds the "+"
// button or the desktop thumbnail, and "presses" it — using the same
// Accessibility system that screen readers use to see and operate buttons.
//
// Called from AppModel.addDesktop() and AppModel.removeDesktop().
//
// Key ideas:
//   • AXUIElement — one on-screen item (a button, a list…) as seen through
//     Accessibility. Each has a role ("AXButton"), a description and
//     actions ("AXPress").
//   • We search the Dock's tree of these items, because the Dock is the
//     app that draws Mission Control.
//   • async/await — the code waits (without freezing the app) for Mission
//     Control to open before looking for its buttons.
// ======================================================================

import AppKit
import ApplicationServices

/// Adds and removes desktops the same way you would by hand: it opens Mission
/// Control and uses the Dock's own accessibility controls — the "+" (add
/// desktop) button and the "remove desktop" action on each desktop thumbnail.
/// macOS has no other supported way to do this. Uses the Accessibility
/// permission SpaceKeeper already has for switching.
enum MissionControl {
    enum Failure: Error {
        case notTrusted, dockNotFound, didNotOpen, controlNotFound

        var message: String {
            switch self {
            case .notTrusted: "SpaceKeeper needs Accessibility permission to add or remove desktops."
            case .dockNotFound: "Couldn't find the Dock."
            case .didNotOpen: "Mission Control didn't open in time. Try again."
            case .controlNotFound: "Couldn't find Mission Control's desktop controls. A macOS update may have changed them."
            }
        }
    }

    /// Adds a desktop at the end of the given display's Spaces bar.
    static func addDesktop(displayIndex: Int, displayCount: Int) async -> Result<Void, Failure> {
        await withMissionControl { bar in
            guard let button = pick(bar.addButtons, displayIndex, displayCount) else { return .failure(.controlNotFound) }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                ? .success(()) : .failure(.controlNotFound)
        }
    }

    /// Removes the Space at `position` (0-based, counting full-screen Spaces too)
    /// on the given display. Its windows move to another desktop, as when you
    /// close a desktop by hand.
    static func removeDesktop(displayIndex: Int, displayCount: Int, position: Int) async -> Result<Void, Failure> {
        await withMissionControl { bar in
            guard let list = pick(bar.spaceLists, displayIndex, displayCount) else { return .failure(.controlNotFound) }
            let buttons = children(of: list)
            guard buttons.indices.contains(position) else { return .failure(.controlNotFound) }
            let button = buttons[position]
            guard actions(of: button).contains("AXRemoveDesktop") else { return .failure(.controlNotFound) }
            return AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString) == .success
                ? .success(()) : .failure(.controlNotFound)
        }
    }

    // MARK: - Mission Control session

    private struct SpacesBar {
        var addButtons: [AXUIElement] = []
        var spaceLists: [AXUIElement] = []
    }

    // The shared routine: open Mission Control → wait up to ~3 seconds for the
    // desktop strip to appear (nudging the pointer to the top of the screen if
    // the strip stays collapsed) → run the add/remove step → close Mission
    // Control with Escape → put the pointer back.
    /// Opens Mission Control, waits for its Spaces bar, runs `body`, then closes it.
    private static func withMissionControl(
        _ body: (SpacesBar) -> Result<Void, Failure>
    ) async -> Result<Void, Failure> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return .failure(.dockNotFound) }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 1.0)

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))

        let originalPointer = CGEvent(source: nil)?.location
        var movedPointer = false
        var bar = SpacesBar()
        for attempt in 0..<30 { // up to ~3 seconds
            try? await Task.sleep(for: .milliseconds(100))
            bar = findSpacesBar(in: dockElement)
            if !bar.spaceLists.isEmpty { break }
            // The Spaces bar stays collapsed until the pointer reaches the top
            // of the screen; if it hasn't appeared after a second, nudge it open.
            if attempt == 10 {
                let top = CGDisplayBounds(CGMainDisplayID())
                movePointer(to: CGPoint(x: top.midX, y: top.minY + 2))
                movedPointer = true
            }
        }

        let result: Result<Void, Failure>
        if bar.spaceLists.isEmpty {
            result = .failure(.didNotOpen)
        } else {
            // Let the opening animation settle so the controls respond.
            try? await Task.sleep(for: .milliseconds(350))
            result = body(bar)
            try? await Task.sleep(for: .milliseconds(600))
        }
        closeMissionControl()
        if movedPointer, let originalPointer { movePointer(to: originalPointer) }
        return result
    }

    private static func movePointer(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func closeMissionControl() {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: isDown)?.post(tap: .cghidEventTap) // Escape
        }
    }

    // MARK: - Accessibility tree

    // Walks the Dock's accessibility tree looking for:
    //   • lists whose items are all buttons → the desktop strip(s)
    //   • a button described as "add desktop" → the "+" button
    // (The Dock's own app icons are "AXDockItem", which is how we tell the
    // strips apart from the Dock itself.)
    /// Walks the Dock's accessibility tree for the Mission Control Spaces bar(s):
    /// lists of desktop buttons, and the "add desktop" buttons. Results are in
    /// tree order, which follows display order.
    private static func findSpacesBar(in root: AXUIElement) -> SpacesBar {
        var bar = SpacesBar()
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 10 else { return }
            let role = string(element, kAXRoleAttribute)
            if role == kAXListRole {
                let items = children(of: element)
                // The Dock's own app list uses AXDockItem; the Spaces bar uses buttons.
                if !items.isEmpty, items.allSatisfy({ string($0, kAXRoleAttribute) == kAXButtonRole }) {
                    bar.spaceLists.append(element)
                    return
                }
            }
            if role == kAXButtonRole {
                let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
                    .compactMap { string(element, $0)?.lowercased() }
                    .joined(separator: " ")
                if label.contains("add desktop") || label.contains("add a desktop") || label.contains("new desktop") {
                    bar.addButtons.append(element)
                    return
                }
            }
            for child in children(of: element) {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return bar
    }

    private static func pick(_ elements: [AXUIElement], _ displayIndex: Int, _ displayCount: Int) -> AXUIElement? {
        if elements.count == displayCount, elements.indices.contains(displayIndex) {
            return elements[displayIndex]
        }
        return elements.first
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }
}
