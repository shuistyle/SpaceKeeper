// ======================================================================
// FullScreenSwitcher.swift — going straight to a full-screen app
// ======================================================================
// When an app goes full screen (a Parallels Desktop virtual machine, a
// video, Keynote…) macOS gives it a Space of its own, after your desktops.
// There's no "Switch to Desktop N" shortcut for those Spaces, and with 16
// desktops there are no shortcuts left anyway. So instead SpaceKeeper does
// what clicking the app's window would do:
//
//   1. Find the window that fills that Space. CGWindowListCopyWindowInfo
//      (public) lists every window and the app that owns it;
//      CGSCopySpacesForWindows (private, read-only) says which Space each
//      window is on.
//   2. Bring exactly that window to the front with SKFocusWindow
//      (CGSPrivate.c), the way window switchers like AltTab do. macOS then
//      slides to the Space holding it: the full-screen one.
//   3. If macOS stays put: mark the window as the app's main window, raise
//      it (Accessibility) and ask the app to become the active app.
//
// AppModel.switchToFullScreen() checks the switch really happened and, if
// not, falls back to pressing the Space's thumbnail in Mission Control.
// Nothing here reads window contents or titles, so no Screen Recording
// permission is needed.
// ======================================================================

import AppKit
import ApplicationServices
import CGSPrivate

/// Private but widely used (AltTab, Rectangle, Hammerspoon): the window
/// number behind an Accessibility window object, so we raise exactly the
/// right window when an app has several.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum FullScreenSwitcher {
    /// The app filling a full-screen Space, and its window(s) there.
    struct Owner {
        let pid: pid_t
        /// Its windows on that Space, largest first (the full-screen window itself).
        let windowIDs: [CGWindowID]
        var appName: String {
            NSRunningApplication(processIdentifier: pid)?.localizedName ?? "the app"
        }
    }

    /// Finds the app whose window fills the Space with this ID, or nil.
    static func owner(ofSpace spaceID: UInt64) -> Owner? {
        guard spaceID != 0,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let connection = CGSMainConnectionID()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var windowsByApp: [pid_t: [(id: CGWindowID, area: Double)]] = [:]

        for window in list {
            // Layer 0 = ordinary app windows (not menus, the Dock or overlays).
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ownPID
            else { continue }
            let ids = [NSNumber(value: number)] as CFArray
            guard let spaces = CGSCopySpacesForWindows(connection, 7, ids),
                  let spaceIDs = (spaces as NSArray) as? [NSNumber],
                  spaceIDs.contains(where: { $0.uint64Value == spaceID })
            else { continue }
            var bounds = CGRect.zero
            if let dict = window[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) ?? .zero
            }
            windowsByApp[pid, default: []].append((number, Double(bounds.width * bounds.height)))
        }
        // Normally exactly one app: the one with the biggest window there.
        guard let best = windowsByApp.max(by: {
            ($0.value.map(\.area).max() ?? 0) < ($1.value.map(\.area).max() ?? 0)
        }) else { return nil }
        let ordered = best.value.sorted { $0.area > $1.area }.map(\.id)
        return Owner(pid: best.key, windowIDs: ordered)
    }

    /// Brings the full-screen window itself to the front (SKFocusWindow), then
    /// raises it. Returns 0 if the window server accepted it, otherwise the
    /// failing step's number (see CGSPrivate.h), for Diagnostics.
    static func focusWindow(_ owner: Owner) -> Int {
        guard let window = owner.windowIDs.first else { return -1 }
        let result = Int(SKFocusWindow(owner.pid, window))
        if result == 0 { _ = raiseWindow(owner) }
        return result
    }

    /// Marks the window as its app's main window and raises it (Accessibility).
    private static func raiseWindow(_ owner: Owner) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let axApp = AXUIElementCreateApplication(owner.pid)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            var number: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &number) == .success,
                  owner.windowIDs.contains(number) else { continue }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        }
        return false
    }

    /// Second way: raises the window and asks its app to become active.
    /// Returns whether the exact window was found and raised.
    @discardableResult
    static func bringForward(_ owner: Owner) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: owner.pid) else { return false }
        let raised = raiseWindow(owner)
        // Not .activateAllWindows: that could pull the app's other windows
        // (on ordinary desktops) forward instead.
        // macOS 14+ "cooperative activation": the app in front (SpaceKeeper,
        // whose tile you just clicked) hands over to the full-screen app.
        NSApp.activate()
        NSApp.yieldActivation(to: app)
        if !app.activate(from: NSRunningApplication.current, options: []) {
            _ = app.activate(options: [])
        }
        return raised
    }
}
