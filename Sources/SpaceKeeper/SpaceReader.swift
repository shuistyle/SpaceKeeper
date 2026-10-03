// ======================================================================
// SpaceReader.swift — asks macOS "which Spaces exist right now?"
// ======================================================================
// macOS has no public way for apps to list Spaces, so this file calls
// three READ-ONLY private functions declared in ../CGSPrivate:
//   CGSMainConnectionID()        our app's connection to the window server
//   CGSGetActiveSpace()          the ID of the Space you're looking at
//   CGSCopyManagedDisplaySpaces() every display and its Spaces, in order
//
// The raw answer is a list of dictionaries (key/value tables). snapshot()
// turns that into the tidy SpaceSnapshot type from Models.swift.
//
// Who calls this: AppModel.refresh() (every 1.5 seconds and whenever you
// switch Space). Overlays.swift also uses screen(forDisplayID:) to find
// the right monitor for each desktop label.
// ======================================================================

import AppKit
import CGSPrivate

/// Reads the current Spaces layout from the window server (read-only).
enum SpaceReader {
    // Builds a SpaceSnapshot. For each display, we walk through its Spaces in
    // order, work out each one's numbers (see SpaceInfo in Models.swift) and
    // whether it is a normal desktop (type 0) or a full-screen app (type 4).
    static func snapshot() -> SpaceSnapshot {
        let connection = CGSMainConnectionID()
        let activeID = CGSGetActiveSpace(connection)

        guard let array = CGSCopyManagedDisplaySpaces(connection),
              let rawDisplays = (array as NSArray) as? [[String: Any]]
        else { return .empty }

        var displays: [DisplaySpaces] = []
        var desktopCounter = 0

        for rawDisplay in rawDisplays {
            // "Main" means "Displays have separate Spaces" is turned off.
            let displayID = rawDisplay["Display Identifier"] as? String ?? "Main"
            let displayName = name(forDisplayID: displayID)
            let current = rawDisplay["Current Space"] as? [String: Any]
            let currentID = number(current?["ManagedSpaceID"]) ?? 0

            var desktopIndex = 0
            var fullScreenIndex = 0
            var spaces: [SpaceInfo] = []

            for (position, raw) in (rawDisplay["Spaces"] as? [[String: Any]] ?? []).enumerated() {
                let managedID = number(raw["ManagedSpaceID"]) ?? number(raw["id64"]) ?? 0
                let uuid = raw["uuid"] as? String ?? ""
                let isFullScreen = number(raw["type"]) == 4

                let index: Int
                if isFullScreen {
                    fullScreenIndex += 1
                    index = fullScreenIndex
                } else {
                    desktopIndex += 1
                    desktopCounter += 1
                    index = desktopIndex
                }

                spaces.append(SpaceInfo(
                    // The original first desktop on a display has an empty UUID.
                    key: uuid.isEmpty ? "\(displayID)#primary" : uuid,
                    managedID: managedID,
                    kind: isFullScreen ? .fullScreen : .desktop,
                    index: index,
                    position: position,
                    desktopNumber: isFullScreen ? nil : desktopCounter,
                    displayID: displayID,
                    displayName: displayName,
                    appName: isFullScreen ? fullScreenAppName(raw) : nil
                ))
            }

            displays.append(DisplaySpaces(
                id: displayID,
                name: displayName,
                currentSpaceID: currentID,
                spaces: spaces
            ))
        }

        return SpaceSnapshot(displays: displays, activeSpaceID: activeID)
    }

    // MARK: Screens

    // Turns macOS's display ID (a UUID text string) into an NSScreen — the
    // AppKit object that knows the screen's size and position.
    static func screen(forDisplayID id: String) -> NSScreen? {
        if id == "Main" { return NSScreen.screens.first }
        return NSScreen.screens.first { uuid(of: $0) == id }
    }

    static func uuid(of screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return SKCopyDisplayUUIDString(number.uint32Value).map { $0 as String }
    }

    private static func name(forDisplayID id: String) -> String {
        if id == "Main" {
            return NSScreen.screens.count > 1 ? "All Displays" : (NSScreen.screens.first?.localizedName ?? "Display")
        }
        return screen(forDisplayID: id)?.localizedName ?? "Display"
    }

    // MARK: Helpers

    private static func number(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }

    private static func fullScreenAppName(_ raw: [String: Any]) -> String? {
        let manager = raw["TileLayoutManager"] as? [String: Any]
        let tiles = manager?["TileSpaces"] as? [[String: Any]] ?? []
        return tiles.lazy.compactMap { $0["appName"] as? String }.first
    }
}
