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
        case notTrusted, dockNotFound, didNotOpen, controlNotFound, desktopsChanged

        var message: String {
            switch self {
            case .notTrusted: "SpaceKeeper needs Accessibility permission to add or remove desktops."
            case .dockNotFound: "Couldn't find the Dock."
            case .didNotOpen: "Mission Control didn't open in time. Try again."
            case .controlNotFound: "Couldn't find Mission Control's desktop controls. A macOS update may have changed them."
            case .desktopsChanged: "Your desktops changed while SpaceKeeper was checking, so nothing was removed. Try again."
            }
        }
    }

    /// Adds a desktop at the end of the given display's Spaces bar.
    /// What happened on the last add attempt — shown in Diagnostics.
    private(set) static var lastAddReport = "not tried"

    static func noteAddStarted() { lastAddReport = "started…" }

    static func addDesktop(displayIndex: Int, displayCount: Int) async -> Result<Void, Failure> {
        await withMissionControl { bar, roots in
            var bar = bar
            var candidates = addButtonCandidates(in: bar)

            // The "+" button only exists once the desktop strip at the top of
            // Mission Control expands, which happens when the pointer reaches
            // the top edge of the screen. If we can't see it yet, nudge the
            // pointer up there and look again for up to 1.5 seconds.
            if candidates.isEmpty {
                let top = CGDisplayBounds(CGMainDisplayID())
                movePointer(to: CGPoint(x: top.midX, y: top.minY + 2))
                for _ in 0..<15 where candidates.isEmpty {
                    try? await Task.sleep(for: .milliseconds(100))
                    bar = findSpacesBar(in: roots)
                    candidates = addButtonCandidates(in: bar)
                }
            }

            guard let button = pick(candidates, displayIndex, displayCount) else {
                lastAddReport = "no + button found (\(bar.spaceLists.count) desktop strip(s) seen)"
                return .failure(.controlNotFound)
            }

            // Try 1: ask the button to press itself (Accessibility "press").
            // We check success by counting the thumbnails in Mission Control's strip.
            let before = thumbnailCount(roots)
            let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            try? await Task.sleep(for: .milliseconds(500))
            if thumbnailCount(roots) > before {
                lastAddReport = "added with Accessibility press"
                return .success(())
            }

            // Try 2: click the middle of the button, like a real mouse click.
            guard let frame = frame(of: button) else {
                lastAddReport = "+ button found, press \(pressed ? "sent" : "failed"), no position to click"
                return .failure(.controlNotFound)
            }
            let point = CGPoint(x: frame.midX, y: frame.midY)
            guard isOnScreen(button, at: point) else {
                lastAddReport = "+ button found, press \(pressed ? "sent" : "failed"); something else was on screen there, so no click was made"
                return .failure(.controlNotFound)
            }
            click(at: point)
            try? await Task.sleep(for: .milliseconds(500))
            let added = thumbnailCount(roots) > before
            lastAddReport = added
                ? "added with a simulated click"
                : "+ button found and clicked, but no desktop appeared"
            return added ? .success(()) : .failure(.controlNotFound)
        }
    }

    /// How many desktop thumbnails Mission Control's strip(s) show right now.
    private static func thumbnailCount(_ roots: [AXUIElement]) -> Int {
        findSpacesBar(in: roots).spaceLists.reduce(0) { $0 + children(of: $1).count }
    }

    /// The "+" buttons: ONLY elements Mission Control itself identifies as
    /// "mc.spaces.add" or labels "add desktop" (found by findSpacesBar).
    /// (Earlier versions also accepted any button next to the desktop strip,
    /// which risked pressing the wrong control. If a future macOS renames the
    /// button, Add Desktop reports "no + button found" instead of guessing.)
    private static func addButtonCandidates(in bar: SpacesBar) -> [AXUIElement] {
        bar.addButtons
    }

    /// Is `button` really what's on screen at `point`? Asks macOS which
    /// element is under that point and compares. Used before a simulated
    /// click, so the click can only ever land on the "+" button itself.
    private static func isOnScreen(_ button: AXUIElement, at point: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit
        else { return false }
        // The hit may be the button itself or something inside it.
        var element: AXUIElement? = hit
        for _ in 0..<4 {
            guard let current = element else { break }
            if CFEqual(current, button) { return true }
            element = parent(of: current)
        }
        return false
    }

    /// Removes one desktop (identified by its Space key) from the given display.
    /// Its windows move to another desktop, as when you close a desktop by hand.
    ///
    /// SAFETY: SpaceKeeper's picture of your desktops can be a second or two
    /// old, and desktops can be moved in between. So, with Mission Control
    /// open (when nothing can move), it re-reads the live layout, finds where
    /// that desktop is NOW, and checks that the thumbnail there is labelled
    /// with the matching number ("Desktop 3"). If anything doesn't match, it
    /// removes nothing — closing the wrong desktop would be worse than not
    /// closing one.
    static func removeDesktop(spaceKey: String, displayID: String, displayIndex: Int, displayCount: Int) async -> Result<Void, Failure> {
        await withMissionControl { bar, _ in
            // 1. Where is the desktop right now?
            let live = SpaceReader.snapshot()
            guard let display = live.displays.first(where: { $0.id == displayID }),
                  let target = display.spaces.first(where: { $0.key == spaceKey }),
                  target.kind == .desktop
            else { return .failure(.desktopsChanged) }

            // 2. Mission Control must show the same number of thumbnails as macOS reports.
            guard let list = pick(bar.spaceLists, displayIndex, displayCount) else { return .failure(.controlNotFound) }
            let buttons = children(of: list)
            guard buttons.count == display.spaces.count,
                  buttons.indices.contains(target.position)
            else { return .failure(.desktopsChanged) }

            // 3. The thumbnail in that place must carry the desktop's number.
            let button = buttons[target.position]
            guard labelNumber(of: button) == target.index else { return .failure(.desktopsChanged) }

            guard actions(of: button).contains("AXRemoveDesktop") else { return .failure(.controlNotFound) }
            return AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString) == .success
                ? .success(()) : .failure(.controlNotFound)
        }
    }

    /// The number at the end of a thumbnail's label: "Desktop 3" → 3. Works in
    /// any language, since only the number is compared. Nil if there's none.
    private static func labelNumber(of button: AXUIElement) -> Int? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let label = string(button, attribute),
               let last = label.split(whereSeparator: \.isWhitespace).last,
               let number = Int(last) {
                return number
            }
        }
        return nil
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
        // @MainActor: the body runs on the main thread like everything else here,
        // so the Accessibility objects never cross threads.
        _ body: @MainActor (SpacesBar, [AXUIElement]) async -> Result<Void, Failure>
    ) async -> Result<Void, Failure> {
        guard AXIsProcessTrusted() else {
            lastAddReport = "no Accessibility permission"
            return .failure(.notTrusted)
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return .failure(.dockNotFound) }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 1.0)

        // Where Mission Control's controls live: on macOS 27 they belong to the
        // WindowManager process; on earlier versions, to the Dock. Search both.
        var roots: [AXUIElement] = []
        if let windowManager = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first {
            let element = AXUIElementCreateApplication(windowManager.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 1.0)
            roots.append(element)
        }
        roots.append(dockElement)

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))

        let originalPointer = CGEvent(source: nil)?.location
        var movedPointer = false
        var bar = SpacesBar()
        for attempt in 0..<50 { // up to ~5 seconds
            try? await Task.sleep(for: .milliseconds(100))
            bar = findSpacesBar(in: roots)
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
            lastAddReport = "Mission Control opened but its desktop strip wasn't recognised — click “Save Mission Control Map” in Diagnostics to help diagnose it"
            result = .failure(.didNotOpen)
        } else {
            // Let the opening animation settle so the controls respond.
            try? await Task.sleep(for: .milliseconds(350))
            result = await body(bar, roots)
            try? await Task.sleep(for: .milliseconds(600))
        }
        closeMissionControl(roots)
        // Put the pointer back where it was (we may have moved it to open the strip).
        _ = movedPointer
        if let originalPointer { movePointer(to: originalPointer) }
        return result
    }

    private static func movePointer(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Closes Mission Control by pressing Escape — but ONLY if Mission Control
    /// is still showing. Otherwise that Escape would go to the app you're
    /// using, where it could cancel a dialog or close a sheet.
    private static func closeMissionControl(_ roots: [AXUIElement]) {
        guard isMissionControlShowing(roots) else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: isDown)?.post(tap: .cghidEventTap) // Escape
        }
    }

    /// True while Mission Control's own controls (identifiers starting "mc",
    /// e.g. "mc.spaces") are on screen. They only exist while it's open.
    private static func isMissionControlShowing(_ roots: [AXUIElement]) -> Bool {
        func search(_ element: AXUIElement, depth: Int) -> Bool {
            guard depth < 8 else { return false }
            if let id = string(element, kAXIdentifierAttribute), id.hasPrefix("mc"),
               !children(of: element).isEmpty {
                return true
            }
            return children(of: element).contains { search($0, depth: depth + 1) }
        }
        return roots.contains { search($0, depth: 0) }
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
    /// Searches each root (WindowManager, then Dock) and stops at the first
    /// one that contains a desktop strip.
    private static func findSpacesBar(in roots: [AXUIElement]) -> SpacesBar {
        for root in roots {
            let bar = findSpacesBar(in: root)
            if !bar.spaceLists.isEmpty { return bar }
        }
        return SpacesBar()
    }

    private static func findSpacesBar(in root: AXUIElement) -> SpacesBar {
        var bar = SpacesBar()
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 16 else { return }
            let role = string(element, kAXRoleAttribute)
            // Apple's own identifiers (seen on macOS 27): the most reliable match.
            switch string(element, kAXIdentifierAttribute) {
            case "mc.spaces.list":
                bar.spaceLists.append(element)
                return
            case "mc.spaces.add":
                bar.addButtons.append(element)
                return
            default:
                break
            }
            if role == kAXListRole, isDesktopStrip(element) {
                bar.spaceLists.append(element)
                return
            }
            if role == kAXButtonRole {
                let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
                    .compactMap { string(element, $0)?.lowercased() }
                    .joined(separator: " ")
                if label.contains("add desktop") || label.contains("add a desktop") || label.contains("new desktop")
                    || label.contains("add space") {
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

    /// Is this list Mission Control's desktop strip (rather than the Dock's own app list)?
    /// The Dock's list contains "AXDockItem"s; the strip contains one item per desktop,
    /// which can close ("AXRemoveDesktop") or is described as a desktop/space.
    private static func isDesktopStrip(_ list: AXUIElement) -> Bool {
        let items = children(of: list)
        guard !items.isEmpty else { return false }
        if items.contains(where: { string($0, kAXRoleAttribute) == "AXDockItem" }) { return false }
        let listLabel = [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute]
            .compactMap { string(list, $0)?.lowercased() }.joined(separator: " ")
        if listLabel.contains("space") || listLabel.contains("desktop") { return true }
        return items.contains { item in
            actions(of: item).contains("AXRemoveDesktop")
                || [kAXDescriptionAttribute, kAXTitleAttribute]
                    .compactMap { string(item, $0)?.lowercased() }
                    .contains { $0.contains("desktop") }
        } || items.allSatisfy { string($0, kAXRoleAttribute) == kAXButtonRole }
    }

    /// Where the map is saved: SpaceKeeper's own log folder (not the system's
    /// DiagnosticReports folder, which macOS gathers into diagnostic bundles).
    static var mapFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SpaceKeeper", isDirectory: true)
            .appendingPathComponent("SpaceKeeper-MissionControl-map.txt")
    }

    /// Only saved when YOU click "Save Mission Control Map" in Diagnostics:
    /// opens Mission Control, writes the map, closes it again, and returns the
    /// file's location.
    static func saveMapOnRequest() async -> URL? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 1.0)
        let originalPointer = CGEvent(source: nil)?.location
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        try? await Task.sleep(for: .seconds(1))
        let top = CGDisplayBounds(CGMainDisplayID())
        movePointer(to: CGPoint(x: top.midX, y: top.minY + 2)) // expands the desktop strip
        try? await Task.sleep(for: .milliseconds(800))
        let path = saveTreeMap(dockElement)
        var roots: [AXUIElement] = []
        if let windowManager = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first {
            let element = AXUIElementCreateApplication(windowManager.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 1.0)
            roots.append(element)
        }
        roots.append(dockElement)
        closeMissionControl(roots)
        if let originalPointer { movePointer(to: originalPointer) }
        return path.map(URL.init(fileURLWithPath:))
    }

    // PRIVACY: the map is an outline of on-screen controls. Labels can include
    // other apps' window titles (document names, email subjects, web pages),
    // so only labels SpaceKeeper needs are written out: those of Mission
    // Control's own controls ("Desktop 3", "add desktop", "Spaces Bar").
    // Every other label is replaced by its length, e.g. ‹hidden, 23 chars›.
    private static func safeLabel(_ text: String) -> String {
        let lower = text.lowercased()
        let allowed = ["desktop", "add desktop", "spaces bar", "spaces", "mission control", "exit to desktop"]
        // Keep "Desktop 3", "exit to Desktop 3", "add desktop" etc.; hide anything else.
        let words = lower.split(whereSeparator: \.isWhitespace)
        let onlySafeWords = !words.isEmpty && words.allSatisfy { word in
            Int(word) != nil || allowed.contains { $0.split(separator: " ").contains(word) }
        }
        return onlySafeWords ? text : "‹hidden, \(text.count) chars›"
    }

    /// Writes an outline of Mission Control's accessibility tree (labels made
    /// private, see safeLabel) to SpaceKeeper's log folder. Returns the path.
    @discardableResult
    private static func saveTreeMap(_ dock: AXUIElement) -> String? {
        var lines: [String] = ["SpaceKeeper map of Mission Control — \(Date()) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]

        func describe(_ element: AXUIElement, depth: Int) {
            guard depth < 12, lines.count < 1500 else { return }
            let kids = children(of: element)
            let childError = lastChildrenError
            let id = string(element, kAXIdentifierAttribute)
            var parts: [String] = [
                string(element, kAXRoleAttribute) ?? "?",
                string(element, kAXSubroleAttribute).map { "subrole=\($0)" },
                string(element, kAXDescriptionAttribute).map { "desc=\"\(safeLabel($0))\"" },
                string(element, kAXTitleAttribute).map { "title=\"\(safeLabel($0))\"" },
                id.map { "id=\($0)" },
                "children=\(kids.count)",
                childError == .success ? nil : "childrenError=\(childError.rawValue)",
                { let a = actions(of: element); return a.isEmpty ? nil : "actions=\(a.joined(separator: ","))" }(),
            ].compactMap { $0 }
            // For Mission Control's own elements, list every attribute they offer.
            if let id, id.hasPrefix("mc") {
                parts.append("attributes=\(attributeNames(of: element).joined(separator: ","))")
            }
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " | "))
            for child in kids where string(child, kAXRoleAttribute) != "AXDockItem" {
                describe(child, depth: depth + 1)
            }
        }

        lines.append("=== Dock ===")
        describe(dock, depth: 0)

        // Mission Control may live in another system process on newer macOS.
        for bundleID in ["com.apple.WindowManager", "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.notificationcenterui"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                lines.append("=== \(bundleID): not running ===")
                continue
            }
            lines.append("=== \(bundleID) ===")
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 1.0)
            describe(element, depth: 0)
        }

        let file = mapFile
        do {
            // Folder readable only by you (permissions 700).
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            return nil
        }
        return file.path
    }

    /// Deletes the saved map (the "Delete Map" button in Diagnostics).
    static func deleteMap() {
        try? FileManager.default.removeItem(at: mapFile)
    }

    private static func pick(_ elements: [AXUIElement], _ displayIndex: Int, _ displayCount: Int) -> AXUIElement? {
        if elements.count == displayCount, elements.indices.contains(displayIndex) {
            return elements[displayIndex]
        }
        return elements.first
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// An element's position and size on screen (top-left origin, like mouse events).
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// A simulated left click at a screen point.
    private static func click(at point: CGPoint) {
        movePointer(to: point)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    /// The last error from reading an element's children (for the map file).
    private static var lastChildrenError: AXError = .success

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        // Mission Control's elements can be slow to answer while it animates,
        // so retry briefly, and try the alternative "visible/navigation" lists.
        for attribute in [kAXChildrenAttribute, kAXVisibleChildrenAttribute, "AXChildrenInNavigationOrder"] {
            for attempt in 0..<3 {
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                lastChildrenError = error
                if error == .success, let list = value as? [AXUIElement], !list.isEmpty { return list }
                if error == .success || error == .noValue || error == .attributeUnsupported { break }
                if attempt < 2 { usleep(50_000) } // busy — wait 0.05 s and retry
            }
        }
        return []
    }

    private static func attributeNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
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
