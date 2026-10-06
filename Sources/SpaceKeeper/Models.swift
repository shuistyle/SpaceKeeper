// ======================================================================
// Models.swift — the app's shared data types, and saving them
// ======================================================================
// "Models" are simple containers of information. They don't DO much; other
// files create, read and change them.
//
//   • SpaceInfo / DisplaySpaces / SpaceSnapshot — built by SpaceReader.swift
//     from what macOS reports. AppModel keeps the latest one in `snapshot`.
//   • SpaceConfig / SpacePin — what YOU have set for each Space (its name,
//     whether it's pinned). Stored in AppModel.configs.
//   • PinAlert — a warning produced by AppModel.evaluatePins() when a
//     pinned desktop has moved; shown by PinAlertsView in MenuPanelView.
//   • AppSettings (+ LabelCorner, LabelLayer, OverlayTextSize) — the
//     switches and pickers in the Settings section of the panel.
//   • Persistence — saves/loads all of the above using UserDefaults
//     (a small built-in macOS storage area for app preferences).
//
// Swift words you'll see:
//   struct       a bundle of values (copied when passed around)
//   enum         a fixed list of choices (e.g. top-left, top-right…)
//   Codable      can be turned into/from JSON text for saving
//   Identifiable has an `id`, so SwiftUI lists can tell items apart
//   nonisolated  safe to use from any thread (plain data, no UI)
// ======================================================================

import Foundation
import CoreGraphics

// MARK: - Live Spaces data (read from the window server)

// ONE Space, as macOS reports it right now. Created in SpaceReader.snapshot().
// Note the different numbers:
//   index         – its number among desktops on its display (1, 2, 3…)
//   position      – its slot in Mission Control's strip, counting
//                   full-screen apps too (used by MissionControl.swift)
//   desktopNumber – its number for the "Switch to Desktop N" shortcuts,
//                   counted across all displays (used by SpaceSwitcher)
nonisolated struct SpaceInfo: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case desktop, fullScreen }

    /// Stable identity. macOS keeps a Space's UUID across logins and reboots.
    let key: String
    /// Window-server ID. Changes between logins, so never persisted.
    let managedID: UInt64
    let kind: Kind
    /// 1-based position among the display's desktops (or among its full-screen Spaces).
    let index: Int
    /// 0-based slot among ALL Spaces on the display (desktops and full-screen),
    /// matching Mission Control's Spaces bar.
    let position: Int
    /// Global desktop number used by the "Switch to Desktop N" shortcuts.
    let desktopNumber: Int?
    let displayID: String
    let displayName: String
    let appName: String?

    var id: String { key }

    var defaultName: String {
        switch kind {
        case .desktop: "Desktop \(index)"
        case .fullScreen: appName.map { "\($0) (full screen)" } ?? "Full-screen app"
        }
    }
}

// All the Spaces on one physical display, in Mission Control's order.
nonisolated struct DisplaySpaces: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let currentSpaceID: UInt64
    let spaces: [SpaceInfo]

    var currentSpace: SpaceInfo? { spaces.first { $0.managedID == currentSpaceID } }
}

// Everything macOS told us in one reading: every display and its Spaces,
// plus which Space is active. AppModel.refresh() compares the new snapshot
// with the old one to notice changes (switches, moves, new desktops).
nonisolated struct SpaceSnapshot: Hashable, Sendable {
    var displays: [DisplaySpaces] = []
    var activeSpaceID: UInt64 = 0

    static let empty = SpaceSnapshot()

    var allSpaces: [SpaceInfo] { displays.flatMap(\.spaces) }
    var activeSpace: SpaceInfo? { allSpaces.first { $0.managedID == activeSpaceID } }
    func space(withKey key: String) -> SpaceInfo? { allSpaces.first { $0.key == key } }
    func display(withID id: String) -> DisplaySpaces? { displays.first { $0.id == id } }
}

// MARK: - Saved per-Space configuration

// A pin = "remember where this desktop sits relative to my other pinned
// desktops". AppModel.evaluatePins() compares this with the live order.
nonisolated struct SpacePin: Codable, Hashable, Sendable {
    var displayID: String
    /// Rank among the pinned desktops on this display (0 = leftmost).
    /// Only the relative order matters, so adding or closing other
    /// desktops never counts as a move.
    var order: Int

    init(displayID: String, order: Int) {
        self.displayID = displayID
        self.order = order
    }

    enum CodingKeys: String, CodingKey { case displayID, order, position }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try c.decode(String.self, forKey: .displayID)
        // Earlier versions stored an absolute "position"; it still works as a rank.
        order = try c.decodeIfPresent(Int.self, forKey: .order)
            ?? c.decodeIfPresent(Int.self, forKey: .position)
            ?? 0
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayID, forKey: .displayID)
        try c.encode(order, forKey: .order)
    }
}

// Your settings for ONE Space (keyed by SpaceInfo.key in AppModel.configs).
// If both name and pin are empty the entry is deleted to keep storage tidy.
nonisolated struct SpaceConfig: Codable, Hashable, Sendable {
    var name: String = ""
    var pin: SpacePin?

    var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pin == nil
    }

    /// Longest name allowed. Long enough for real names, short enough to fit
    /// the menu bar, tiles and notifications, and to keep saved settings small.
    static let maxNameLength = 60

    /// Tidies a typed or pasted name: line breaks, tabs and other invisible
    /// control characters become spaces, runs of spaces become one, the ends
    /// are trimmed, and it's cut to `maxNameLength` characters.
    static func cleanedName(_ raw: String) -> String {
        let flattened = String(raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? " " : Character(scalar)
        })
        let collapsed = flattened.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maxNameLength))
    }
}

// A warning about one pinned desktop. `title` and `message` are the words
// shown in the panel (PinAlertsView) and in notifications.
nonisolated struct PinAlert: Identifiable, Hashable, Sendable {
    enum Problem: Hashable, Sendable {
        /// Out of order relative to the other pinned desktops. Names of the pinned
        /// desktops it should sit after / before (nil at either end).
        case outOfOrder(after: String?, before: String?)
        case otherDisplay(String)
        case missing
    }

    let key: String
    let name: String
    let expectedDisplayName: String
    let problem: Problem

    var id: String { key }

    var isMoved: Bool { problem != .missing }

    var title: String {
        switch problem {
        case .outOfOrder: "“\(name)” is out of order"
        case .otherDisplay: "“\(name)” moved display"
        case .missing: "“\(name)” is missing"
        }
    }

    var message: String {
        switch problem {
        case let .outOfOrder(after?, before?):
            "It should sit after “\(after)” and before “\(before)”."
        case let .outOfOrder(after?, nil):
            "It should sit after “\(after)”."
        case let .outOfOrder(nil, before?):
            "It should sit before “\(before)”."
        case .outOfOrder(nil, nil):
            "It's no longer in its pinned order."
        case let .otherDisplay(display):
            "It was pinned on \(expectedDisplayName) but is now on \(display)."
        case .missing:
            "This pinned desktop no longer exists on \(expectedDisplayName). It may have been closed in Mission Control."
        }
    }
}

// MARK: - App settings

// Which corner of each desktop the name label sits in (Settings › Corner).
// Used by DesktopLabelManager in Overlays.swift.
nonisolated enum LabelCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: Self { self }
    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
}

// Whether desktop labels sit on the wallpaper (behind windows) or float
// above windows (Settings › Layer).
nonisolated enum LabelLayer: String, Codable, CaseIterable, Identifiable, Sendable {
    case desktop, floating
    var id: Self { self }
    var title: String {
        switch self {
        case .desktop: "On wallpaper"
        case .floating: "Above windows"
        }
    }
}

// Accessibility: text and icon size for the PANEL itself (Settings › Text size,
// or ⌘+ / ⌘− / ⌘0 while the panel is open). macOS doesn't let menu bar apps
// follow a system-wide text size, so SpaceKeeper offers its own. "Largest"
// doubles everything, meeting the WCAG 1.4.4 "resize text to 200 %" guideline.
nonisolated enum PanelTextSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, large, extraLarge, largest
    var id: Self { self }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .large: "Large"
        case .extraLarge: "Extra large"
        case .largest: "Largest (200 %)"
        }
    }
    /// Multiplier applied to every font, icon and the panel width.
    var scale: CGFloat {
        switch self {
        case .standard: 1.0
        case .large: 1.3
        case .extraLarge: 1.6
        case .largest: 2.0
        }
    }
    var bigger: PanelTextSize { Self.allCases[min(Self.allCases.firstIndex(of: self)! + 1, Self.allCases.count - 1)] }
    var smaller: PanelTextSize { Self.allCases[max(Self.allCases.firstIndex(of: self)! - 1, 0)] }
}

// Accessibility: text size for the desktop labels and the switch banner
// (Settings › Label and banner size). Used in Overlays.swift.
nonisolated enum OverlayTextSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, large, extraLarge
    var id: Self { self }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .large: "Large"
        case .extraLarge: "Extra large"
        }
    }
    var hudPoints: CGFloat {
        switch self {
        case .standard: 34
        case .large: 44
        case .extraLarge: 56
        }
    }
    var labelPoints: CGFloat {
        switch self {
        case .standard: 20
        case .large: 26
        case .extraLarge: 34
        }
    }
}

// Every user setting in one place. AppModel exposes each one as a property
// (e.g. AppModel.showHUD) so the switches in the panel can change it.
// The custom `init(from:)` below fills in a default for any setting that
// is missing from older saved data, so adding a new setting never wipes
// the user's existing choices.
nonisolated struct AppSettings: Codable, Hashable, Sendable {
    var showHUD = true
    var showNameInMenuBar = true
    var showDesktopLabels = true
    var labelCorner: LabelCorner = .bottomLeft
    var labelLayer: LabelLayer = .desktop
    var labelOpacity: Double = 0.85
    var notifyPinMoves = false
    var openWithModifierTap = true   // double-tap ⌃ / ⌃⌥S on (old name kept so saved settings still load)
    var overlayTextSize: OverlayTextSize = .standard
    var panelTextSize: PanelTextSize = .standard

    enum CodingKeys: String, CodingKey {
        case showHUD, showNameInMenuBar, showDesktopLabels, labelCorner, labelLayer, labelOpacity, notifyPinMoves, openWithModifierTap, overlayTextSize, panelTextSize
    }

    init() {}

    // Tolerant decoding so new settings never wipe saved ones.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        showHUD = try c.decodeIfPresent(Bool.self, forKey: .showHUD) ?? d.showHUD
        showNameInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showNameInMenuBar) ?? d.showNameInMenuBar
        showDesktopLabels = try c.decodeIfPresent(Bool.self, forKey: .showDesktopLabels) ?? d.showDesktopLabels
        labelCorner = try c.decodeIfPresent(LabelCorner.self, forKey: .labelCorner) ?? d.labelCorner
        labelLayer = try c.decodeIfPresent(LabelLayer.self, forKey: .labelLayer) ?? d.labelLayer
        labelOpacity = try c.decodeIfPresent(Double.self, forKey: .labelOpacity) ?? d.labelOpacity
        notifyPinMoves = try c.decodeIfPresent(Bool.self, forKey: .notifyPinMoves) ?? d.notifyPinMoves
        openWithModifierTap = try c.decodeIfPresent(Bool.self, forKey: .openWithModifierTap) ?? d.openWithModifierTap
        overlayTextSize = try c.decodeIfPresent(OverlayTextSize.self, forKey: .overlayTextSize) ?? d.overlayTextSize
        panelTextSize = try c.decodeIfPresent(PanelTextSize.self, forKey: .panelTextSize) ?? d.panelTextSize
    }
}

// MARK: - Persistence

// Saving and loading. Everything is turned into JSON text (or a simple
// dictionary) and stored in UserDefaults under the keys below. The ".v1"
// in each key is a version label, so a future format can use a new key.
enum Persistence {
    private static let configsKey = "spaceConfigs.v1"
    private static let settingsKey = "settings.v1"

    static func loadConfigs() -> [String: SpaceConfig] {
        guard let data = UserDefaults.standard.data(forKey: configsKey),
              var value = try? JSONDecoder().decode([String: SpaceConfig].self, from: data)
        else { return [:] }
        // Tidy names saved before the length limit existed (or edited by hand).
        for key in value.keys { value[key]?.name = SpaceConfig.cleanedName(value[key]?.name ?? "") }
        return value
    }

    static func save(_ configs: [String: SpaceConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: configsKey)
        }
    }

    private static let listOrderKey = "listOrder.v1"

    /// The user's own order for the SpaceKeeper list, per display (Space keys).
    static func loadListOrder() -> [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: listOrderKey) as? [String: [String]]) ?? [:]
    }

    static func saveListOrder(_ order: [String: [String]]) {
        UserDefaults.standard.set(order, forKey: listOrderKey)
    }

    static func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let value = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return value
    }

    static func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }
}

// Small helper: shortens long names with "…" (used in the menu bar).
extension String {
    func truncated(to length: Int) -> String {
        count > length ? String(prefix(length - 1)) + "…" : self
    }
}
