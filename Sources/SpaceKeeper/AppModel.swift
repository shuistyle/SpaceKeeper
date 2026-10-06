// ======================================================================
// AppModel.swift — the "brain" of SpaceKeeper
// ======================================================================
// There is exactly ONE AppModel, created in SpaceKeeperApp.swift. It:
//   1. HOLDS the app's state: the latest snapshot of your Spaces, your
//      names/pins (configs), your settings, warnings and messages.
//   2. DOES things when asked: rename, pin, switch, add/remove desktops,
//      reorder the list, change settings.
//   3. WATCHES macOS for changes (Space switches, screen changes) and
//      re-checks every 1.5 seconds.
//
// Views (Views/MenuPanelView.swift) read its properties and call its
// functions. Because the class is marked @Observable, SwiftUI notices when
// a property changes and redraws only the parts of the screen that use it.
//
// It hands the low-level work to helper files:
//   SpaceReader      – read Spaces            HUDController / DesktopLabelManager
//   SpaceSwitcher    – switch desktops          (Overlays.swift) – on-screen text
//   DockPreferences  – fixed-order setting    MissionControl  – add/remove desktops
//   Persistence      – save/load (Models)     DoubleTapControl / GlobalHotKey /
//   A11y             – VoiceOver, display       QuickPanelController – the panel
//                      preferences
//
// Tip: "private" means only code inside this class can use it; everything
// else is available to the views. `@ObservationIgnored` marks helper
// objects that SwiftUI doesn't need to watch.
// ======================================================================

import AppKit
import Observation
import ServiceManagement
import UserNotifications

@Observable
final class AppModel {
    // --- STATE ---------------------------------------------------------------
    // The data views display. `private(set)` = views can read it but only
    // AppModel may change it (so every change goes through one place).
    //   snapshot      – latest reading from SpaceReader
    //   configs       – your names and pins, keyed by Space key
    //   settings      – everything in the Settings section
    //   listOrder     – your custom order for the panel list (per display)
    //   pinAlerts     – warnings shown in the orange box
    //   statusMessage – the grey message under the settings
    // MARK: State

    private(set) var snapshot: SpaceSnapshot = .empty
    private(set) var configs: [String: SpaceConfig] = Persistence.loadConfigs()
    private(set) var settings: AppSettings = Persistence.loadSettings()
    /// Order of desktops in SpaceKeeper's list, per display. Only affects this
    /// app's list — Mission Control keeps its own order.
    private(set) var listOrder: [String: [String]] = Persistence.loadListOrder()
    private(set) var pinAlerts: [PinAlert] = []
    private(set) var autoRearrangeEnabled = DockPreferences.autoRearrangeEnabled
    private(set) var accessibilityTrusted = SpaceSwitcher.isTrusted
    private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    var statusMessage: String?

    @ObservationIgnored private let hud = HUDController()
    @ObservationIgnored private let labels = DesktopLabelManager()
    @ObservationIgnored private let openHotKey = GlobalHotKey()
    @ObservationIgnored private let doubleTap = DoubleTapControl()
    @ObservationIgnored private var quickPanel: QuickPanelController?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var notifiedAlertKeys: Set<String> = []

    /// Notifications and login items only work from a real .app bundle
    /// (not when run straight from `swift run`).
    private static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: Lifecycle

    // Called once at launch (AppDelegate). Sets everything in motion:
    //   • reads the Spaces for the first time
    //   • sets up the double-tap Control / ⌃⌥S shortcuts and quick panel (OpenShortcut.swift)
    //   • listens for macOS notifications: Space switched, screens changed,
    //     accessibility display settings changed
    //   • starts a loop that calls refresh() every 1.5 seconds, because
    //     dragging desktops around in Mission Control sends no notification
    //   • asks permission to show notifications
    func start() {
        guard pollTask == nil else { return }
        refresh(force: true)

        let quickPanel = QuickPanelController(model: self)
        self.quickPanel = quickPanel
        openHotKey.onPress = { quickPanel.toggle() }
        doubleTap.onPress = { quickPanel.toggle() }
        updateOpenShortcut()

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        })
        // Redraw labels when Reduce Transparency / Increase Contrast change.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        })

        // Reordering Spaces in Mission Control posts no notification, so poll lightly.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                self?.refresh()
            }
        }

        if Self.isBundled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // Called by MenuPanelView whenever the panel opens: re-reads settings that
    // can change outside the app (Dock setting, permissions, login item).
    func panelDidAppear() {
        autoRearrangeEnabled = DockPreferences.autoRearrangeEnabled
        accessibilityTrusted = SpaceSwitcher.isTrusted
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        refresh(force: true)
    }

    private func handleSpaceChange() {
        refresh()
        // The window server can lag the notification slightly; check again.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.refresh()
        }
    }

    // The heartbeat. Takes a new snapshot and, if anything changed:
    //   • stores it (views redraw automatically)
    //   • re-checks pins (evaluatePins)
    //   • updates the desktop labels (syncLabels → Overlays.swift)
    //   • if you changed Space: tells VoiceOver and shows the switch banner (HUD)
    // `force: true` does all of this even when nothing seems to have changed.
    func refresh(force: Bool = false) {
        let trusted = SpaceSwitcher.isTrusted
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }

        let new = SpaceReader.snapshot()
        guard force || new != snapshot else { return }

        let previousActive = snapshot.activeSpaceID
        snapshot = new
        evaluatePins()
        syncLabels()

        if previousActive != 0, previousActive != new.activeSpaceID, let space = new.activeSpace {
            A11y.announce("\(displayName(for: space)), \(space.defaultName)")
        }
        if previousActive != 0, previousActive != new.activeSpaceID,
           settings.showHUD, let space = new.activeSpace {
            hud.show(title: displayName(for: space), subtitle: hudSubtitle(for: space), textSize: settings.overlayTextSize)
        }
    }

    // --- NAMES ---------------------------------------------------------------
    // displayName(for:) is used everywhere a Space's name is shown: your
    // custom name if you typed one, otherwise macOS's default ("Desktop 3").
    // MARK: Names

    var currentSpace: SpaceInfo? { snapshot.activeSpace }

    func customName(for key: String) -> String { configs[key]?.name ?? "" }

    func displayName(for space: SpaceInfo) -> String {
        let name = customName(for: space.key).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? space.defaultName : name
    }

    func rename(_ space: SpaceInfo, to name: String) {
        let name = SpaceConfig.cleanedName(name) // max 60 characters, no line breaks
        updateConfig(space.key) { $0.name = name }
        evaluatePins()
        syncLabels()
    }

    private func hudSubtitle(for space: SpaceInfo) -> String? {
        var parts: [String] = []
        if !customName(for: space.key).trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(space.defaultName)
        }
        if snapshot.displays.count > 1 { parts.append(space.displayName) }
        if isPinned(space) { parts.append("Pinned") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // --- PINNING -------------------------------------------------------------
    // A pin records a desktop's place relative to your OTHER pinned desktops
    // (see SpacePin in Models.swift). evaluatePins() runs after every refresh
    // and produces PinAlerts when that order has been broken.
    // MARK: Pinning

    var hasPins: Bool { configs.values.contains { $0.pin != nil } }

    func isPinned(_ space: SpaceInfo) -> Bool { configs[space.key]?.pin != nil }

    func alert(for space: SpaceInfo) -> PinAlert? { pinAlerts.first { $0.key == space.key } }

    func togglePin(_ space: SpaceInfo) {
        guard space.kind == .desktop else { return }
        if isPinned(space) {
            updateConfig(space.key) { $0.pin = nil }
        } else {
            // Slot the new pin into the saved order according to where it sits now.
            let display = space.displayID
            var ordered = configs
                .compactMap { key, config -> (key: String, order: Int)? in
                    guard let pin = config.pin, pin.displayID == display else { return nil }
                    return (key, pin.order)
                }
                .sorted { ($0.order, $0.key) < ($1.order, $1.key) }
                .map(\.key)
            let insertAt = ordered.firstIndex { key in
                guard let other = snapshot.space(withKey: key), other.displayID == display else { return false }
                return other.index > space.index
            } ?? ordered.count
            ordered.insert(space.key, at: insertAt)
            for (rank, key) in ordered.enumerated() {
                updateConfig(key) { $0.pin = SpacePin(displayID: display, order: rank) }
            }
            if autoRearrangeEnabled {
                statusMessage = "Tip: turn on “Keep Spaces in a fixed order” so macOS doesn't move pinned Spaces."
            }
        }
        evaluatePins()
    }

    /// Saves the current arrangement as the new pinned order.
    func acceptCurrentOrder() {
        var byDisplay: [String: [SpaceInfo]] = [:]
        for (key, config) in configs where config.pin != nil {
            if let space = snapshot.space(withKey: key) {
                byDisplay[space.displayID, default: []].append(space)
            }
        }
        for (displayID, spaces) in byDisplay {
            for (rank, space) in spaces.sorted(by: { $0.index < $1.index }).enumerated() {
                updateConfig(space.key) { $0.pin = SpacePin(displayID: displayID, order: rank) }
            }
        }
        statusMessage = "Saved the current order of your pinned desktops."
        evaluatePins()
    }

    func unpin(key: String) {
        updateConfig(key) { $0.pin = nil }
        evaluatePins()
    }

    // How the check works, step by step:
    //   1. Group pinned desktops by display, in their saved order.
    //   2. Note any that vanished (closed) or moved to another display.
    //   3. For the rest, look at their CURRENT positions. The longest run that
    //      is still in increasing order counts as "in place"; only the others
    //      are flagged. This way one moved desktop produces one warning,
    //      not a warning for every desktop after it.
    //   4. Announce new warnings to VoiceOver and (optionally) post a system
    //      notification, then publish the list for the panel to show.
    /// Checks that pinned desktops are still in the same order relative to each
    /// other. Unpinned desktops being added, closed or moved don't matter.
    private func evaluatePins() {
        guard !snapshot.displays.isEmpty else { return }
        let liveDisplays = Set(snapshot.displays.map(\.id))
        let pinned = configs.compactMap { key, config in
            config.pin.map { (key: key, config: config, pin: $0) }
        }
        var alerts: [PinAlert] = []

        // Pins for displays that are currently disconnected are skipped.
        for displayID in Set(pinned.map(\.pin.displayID)) where liveDisplays.contains(displayID) {
            let displayName = snapshot.display(withID: displayID)?.name ?? "its display"
            let group = pinned
                .filter { $0.pin.displayID == displayID }
                .sorted { ($0.pin.order, $0.key) < ($1.pin.order, $1.key) }

            var present: [SpaceInfo] = []   // still on this display, in saved order
            for item in group {
                if let space = snapshot.space(withKey: item.key) {
                    if space.displayID == displayID {
                        present.append(space)
                    } else {
                        alerts.append(PinAlert(key: item.key, name: self.displayName(for: space),
                                               expectedDisplayName: displayName,
                                               problem: .otherDisplay(space.displayName)))
                    }
                } else {
                    let name = item.config.name.trimmingCharacters(in: .whitespaces)
                    alerts.append(PinAlert(key: item.key, name: name.isEmpty ? "Pinned desktop" : name,
                                           expectedDisplayName: displayName, problem: .missing))
                }
            }

            // Keep the largest set already in the right order; flag only the rest.
            let inOrder = Self.longestIncreasingRun(present.map(\.index))
            for (i, space) in present.enumerated() where !inOrder.contains(i) {
                let after = present.indices.prefix(i).last { inOrder.contains($0) }
                let before = present.indices.suffix(from: i + 1).first { inOrder.contains($0) }
                alerts.append(PinAlert(
                    key: space.key,
                    name: self.displayName(for: space),
                    expectedDisplayName: displayName,
                    problem: .outOfOrder(
                        after: after.map { self.displayName(for: present[$0]) },
                        before: before.map { self.displayName(for: present[$0]) }
                    )
                ))
            }
        }

        alerts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if settings.notifyPinMoves {
            for alert in alerts where !notifiedAlertKeys.contains(alert.key) {
                postNotification(for: alert)
            }
        }
        if let first = alerts.first(where: { !notifiedAlertKeys.contains($0.key) }) {
            A11y.announce("SpaceKeeper: \(first.title). \(first.message)", important: true)
        }
        notifiedAlertKeys = Set(alerts.map(\.key))
        if alerts != pinAlerts { pinAlerts = alerts }
    }

    // Standard "longest increasing subsequence" algorithm. Example: positions
    // [1, 4, 2, 3] → the run 1, 2, 3 is in order, so only the "4" is flagged.
    /// Indices of the longest strictly increasing subsequence of `values`.
    private static func longestIncreasingRun(_ values: [Int]) -> Set<Int> {
        guard !values.isEmpty else { return [] }
        var length = Array(repeating: 1, count: values.count)
        var previous = Array(repeating: -1, count: values.count)
        for i in values.indices {
            for j in 0..<i where values[j] < values[i] && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                previous[i] = j
            }
        }
        var i = length.indices.max { length[$0] < length[$1] } ?? 0
        var result: Set<Int> = []
        while i >= 0 {
            result.insert(i)
            i = previous[i]
        }
        return result
    }

    private func postNotification(for alert: PinAlert) {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        let request = UNNotificationRequest(identifier: "pin-\(alert.key)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // --- OPENING THE PANEL AND JUMPING ---------------------------------------
    // The panel is the floating window from QuickPanelController
    // (OpenShortcut.swift), opened by the menu bar icon (StatusItemController)
    // or the ⌃⌥S shortcut. `panelOpenCount` goes up each time it opens so the
    // grid can put keyboard focus on the current desktop.
    private(set) var panelOpenCount = 0

    /// The desktop whose name is being edited in its tile (nil = none).
    var renamingKey: String?

    @ObservationIgnored private var pendingJump: Task<Void, Never>?

    func toggleQuickPanel() { quickPanel?.toggle() }
    func closeQuickPanel() { quickPanel?.close() }
    func quickPanelDidOpen() { panelOpenCount += 1 }

    /// Jumps to a desktop and closes the panel. When `waitForDoubleClick` is
    /// true (a mouse click), it waits one double-click interval first, so a
    /// second click can turn the action into "rename" instead.
    func jump(to space: SpaceInfo, waitForDoubleClick: Bool = false) {
        pendingJump?.cancel()
        guard canSwitch(to: space), space.managedID != snapshot.activeSpaceID else { return }
        pendingJump = Task { [weak self] in
            if waitForDoubleClick {
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            }
            guard !Task.isCancelled, let self else { return }
            self.closeQuickPanel()
            self.switchTo(space)
        }
    }

    func startRenaming(_ space: SpaceInfo) {
        guard space.kind == .desktop else { return }
        pendingJump?.cancel()
        pendingJump = nil
        renamingKey = space.key
    }

    /// Ends renaming. Pass nil to cancel (keep the old name).
    func finishRenaming(_ space: SpaceInfo, newName: String?) {
        if let newName { rename(space, to: newName) }
        if renamingKey == space.key { renamingKey = nil }
    }


    // --- LIST ORDER ----------------------------------------------------------
    // Your own order for the rows in the panel (drag ≡, Move Up/Down, ⌥⌘↑↓).
    // This ONLY changes SpaceKeeper's list — Mission Control is untouched.
    // Saved per display in `listOrder` via Persistence.
    // MARK: List order (SpaceKeeper only)

    /// The display's Spaces in the user's list order. Desktops not yet placed
    /// (e.g. newly added) go after the placed ones; full-screen Spaces stay last.
    func orderedSpaces(for display: DisplaySpaces) -> [SpaceInfo] {
        let desktops = display.spaces.filter { $0.kind == .desktop }
        let fullScreen = display.spaces.filter { $0.kind == .fullScreen }
        guard let saved = listOrder[display.id], !saved.isEmpty else { return desktops + fullScreen }
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = desktops
            .filter { rank[$0.key] != nil }
            .sorted { rank[$0.key, default: 0] < rank[$1.key, default: 0] }
        let unplaced = desktops.filter { rank[$0.key] == nil }
        return placed + unplaced + fullScreen
    }

    func hasCustomOrder(_ display: DisplaySpaces) -> Bool {
        let current = orderedSpaces(for: display).filter { $0.kind == .desktop }.map(\.key)
        let missionControl = display.spaces.filter { $0.kind == .desktop }.map(\.key)
        return current != missionControl
    }

    /// Drag and drop: puts `key` where `target` is, on the same display.
    func move(key: String, to target: SpaceInfo) {
        guard key != target.key,
              let display = snapshot.display(withID: target.displayID),
              target.kind == .desktop
        else { return }
        var keys = orderedSpaces(for: display).filter { $0.kind == .desktop }.map(\.key)
        guard let from = keys.firstIndex(of: key), let to = keys.firstIndex(of: target.key) else { return }
        keys.remove(at: from)
        keys.insert(key, at: to) // moving down lands after the target, moving up lands before it
        saveOrder(keys, for: display.id)
    }

    func canMove(_ space: SpaceInfo, by offset: Int) -> Bool {
        guard space.kind == .desktop, let display = snapshot.display(withID: space.displayID) else { return false }
        let keys = orderedSpaces(for: display).filter { $0.kind == .desktop }.map(\.key)
        guard let index = keys.firstIndex(of: space.key) else { return false }
        return keys.indices.contains(index + offset)
    }

    /// Move Up (-1) / Move Down (+1).
    func move(_ space: SpaceInfo, by offset: Int) {
        guard canMove(space, by: offset), let display = snapshot.display(withID: space.displayID) else { return }
        var keys = orderedSpaces(for: display).filter { $0.kind == .desktop }.map(\.key)
        guard let index = keys.firstIndex(of: space.key) else { return }
        keys.swapAt(index, index + offset)
        saveOrder(keys, for: display.id)
    }

    func resetOrder(for display: DisplaySpaces) {
        listOrder[display.id] = nil
        Persistence.saveListOrder(listOrder)
    }

    private func saveOrder(_ keys: [String], for displayID: String) {
        listOrder[displayID] = keys
        Persistence.saveListOrder(listOrder)
    }

    // --- ADD / REMOVE DESKTOPS -----------------------------------------------
    // The real work is in MissionControl.swift. These functions guard against
    // double-clicks (isChangingDesktops), check the result by refreshing, and
    // tidy up a removed desktop's saved name and pin. Removing is two-step:
    // requestRemoval() shows Remove/Cancel in the row, removeDesktop() acts.
    // MARK: Adding and removing desktops

    /// True while SpaceKeeper is driving Mission Control.
    private(set) var isChangingDesktops = false
    /// Desktop awaiting the user's "Remove" confirmation.
    var pendingRemovalKey: String?

    func canRemove(_ space: SpaceInfo) -> Bool {
        guard space.kind == .desktop, !isChangingDesktops,
              let display = snapshot.display(withID: space.displayID) else { return false }
        return display.spaces.filter { $0.kind == .desktop }.count > 1
    }

    /// macOS allows at most 16 desktops on each display.
    static let maxDesktopsPerDisplay = 16

    /// The display a new desktop would be added to: the one you're on.
    private var addTargetDisplay: DisplaySpaces? {
        let displayID = snapshot.activeSpace?.displayID ?? snapshot.displays.first?.id
        return snapshot.displays.first { $0.id == displayID }
    }

    /// How many desktops (not counting full-screen apps) that display has.
    var desktopCountOnCurrentDisplay: Int {
        addTargetDisplay?.spaces.filter { $0.kind == .desktop }.count ?? 0
    }

    /// True when that display already has the macOS maximum of 16 desktops.
    /// The Add Desktop button greys out; removing a desktop re-enables it,
    /// because the count is re-read from macOS on every refresh.
    var isAtDesktopLimit: Bool {
        desktopCountOnCurrentDisplay >= Self.maxDesktopsPerDisplay
    }

    var canAddDesktop: Bool { !isChangingDesktops && !isAtDesktopLimit }

    /// Adds a desktop to the display you're currently on.
    func addDesktop() {
        guard !isChangingDesktops else { return }
        guard !isAtDesktopLimit else {
            statusMessage = "You have \(Self.maxDesktopsPerDisplay) desktops, the most macOS allows. Remove one to add another."
            return
        }
        MissionControl.noteAddStarted()
        let displayID = snapshot.activeSpace?.displayID ?? snapshot.displays.first?.id
        let displayIndex = snapshot.displays.firstIndex { $0.id == displayID } ?? 0
        let before = snapshot.allSpaces.count
        isChangingDesktops = true
        Task { [weak self] in
            let result = await MissionControl.addDesktop(displayIndex: displayIndex,
                                                         displayCount: self?.snapshot.displays.count ?? 1)
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.refresh(force: true)
            self.isChangingDesktops = false
            switch result {
            case .failure(let failure):
                self.statusMessage = failure.message
            case .success where self.snapshot.allSpaces.count > before:
                self.statusMessage = "Added a desktop. Type in its row to name it."
            case .success:
                self.statusMessage = "Mission Control didn't add a desktop. Try again."
            }
        }
    }

    func requestRemoval(of space: SpaceInfo) { pendingRemovalKey = space.key }
    func cancelRemoval() { pendingRemovalKey = nil }

    /// Removes a desktop. Its windows move to another desktop, exactly as when
    /// you close one in Mission Control. Its name and pin are cleared too.
    func removeDesktop(_ space: SpaceInfo) {
        pendingRemovalKey = nil
        guard canRemove(space),
              let displayIndex = snapshot.displays.firstIndex(where: { $0.id == space.displayID })
        else { return }
        let name = displayName(for: space)
        isChangingDesktops = true
        Task { [weak self] in
            let result = await MissionControl.removeDesktop(spaceKey: space.key,
                                                            displayID: space.displayID,
                                                            displayIndex: displayIndex,
                                                            displayCount: self?.snapshot.displays.count ?? 1)
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.refresh(force: true)
            self.isChangingDesktops = false
            switch result {
            case .failure(let failure):
                self.statusMessage = failure.message
            case .success where self.snapshot.space(withKey: space.key) == nil:
                self.updateConfig(space.key) { $0 = SpaceConfig() }
                self.evaluatePins()
                self.syncLabels()
                self.statusMessage = "Removed “\(name)”. Any windows on it moved to another desktop."
            case .success:
                self.statusMessage = "Mission Control didn't remove “\(name)”. Try again."
            }
        }
    }

    // --- FIXED ORDER ---------------------------------------------------------
    // "Keep Spaces in a fixed order" switches off macOS's habit of reordering
    // Spaces by recent use. Implemented in DockPreferences (SystemBridges.swift).
    // MARK: Fixed order (Dock setting)

    var keepSpacesInOrder: Bool {
        get { !autoRearrangeEnabled }
        set { setAutoRearrange(!newValue) }
    }

    func setAutoRearrange(_ enabled: Bool) {
        do {
            try DockPreferences.setAutoRearrange(enabled)
            statusMessage = enabled
                ? "macOS will now rearrange Spaces by recent use."
                : "Space order locked. macOS will no longer move your Spaces around."
        } catch {
            statusMessage = error.localizedDescription
        }
        autoRearrangeEnabled = DockPreferences.autoRearrangeEnabled
        // The Dock restarts; re-read Spaces once it's back.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.refresh(force: true)
        }
    }

    // --- SWITCHING DESKTOPS --------------------------------------------------
    // macOS has no "go to Space N" function for apps, so SpaceSwitcher
    // (SystemBridges.swift) presses your "Switch to Desktop N" keyboard
    // shortcut for you. switchTo() then checks a second later that the switch
    // really happened and explains what to fix if it didn't.
    // MARK: Switching

    func canSwitch(to space: SpaceInfo) -> Bool {
        space.desktopNumber != nil
    }

    /// What happened on the last jump, for Diagnostics.
    private(set) var lastSwitchReport = "No switch tried yet"

    /// Apps known to turn macOS's desktop shortcuts off while they're in
    /// front (virtual machines and remote-desktop apps), by bundle ID prefix.
    /// Add to this list if another app turns out to do the same.
    private static let shortcutBlockingApps = [
        "com.parallels.",            // Parallels Desktop and its VM windows
        "com.vmware.fusion",         // VMware Fusion
        "com.utmapp.",               // UTM
        "org.virtualbox.",           // VirtualBox
        "com.microsoft.rdc",         // Windows App / Microsoft Remote Desktop
        "com.citrix.",               // Citrix Workspace
        "com.vmware.horizon", "com.omnissa.horizon", // Horizon Client
        "com.apple.ScreenSharing",   // Screen Sharing
        "com.teamviewer.", "com.realvnc.",
    ]

    private static func blocksDesktopShortcuts(_ app: NSRunningApplication?) -> Bool {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier
        else { return false }
        return shortcutBlockingApps.contains { bundleID.hasPrefix($0) }
    }

    func switchTo(_ space: SpaceInfo) {
        guard let number = space.desktopNumber else { return }
        if !SpaceSwitcher.isTrusted { SpaceSwitcher.requestTrust() }
        let startingSpace = snapshot.activeSpaceID
        Task { [weak self] in
            // Give the menu bar panel a moment to close before pressing the shortcut.
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            // The app you were using. Some apps — Parallels Desktop, other virtual
            // machines and remote-desktop apps — switch macOS's desktop shortcuts
            // OFF while they're in front, so they can pass the keys to the other
            // computer. ONLY for those apps, if the first press doesn't work,
            // SpaceKeeper briefly makes itself the active app (which makes that
            // app turn the shortcuts back on) and presses again. For any other
            // app it never takes the keyboard away.
            let frontApp = NSWorkspace.shared.frontmostApplication
            let frontName = frontApp?.localizedName ?? "unknown app"
            let mayRetry = Self.blocksDesktopShortcuts(frontApp)

            switch SpaceSwitcher.switchTo(desktop: number) {
            case .failure(let error):
                self.statusMessage = error.message
                self.lastSwitchReport = "Desktop \(number): not attempted — \(error.message)"
            case .success(let shortcut):
                // The switch animation takes about half a second.
                try? await Task.sleep(for: .milliseconds(900))
                self.refresh()
                var moved = self.snapshot.activeSpaceID != startingSpace
                var retried = false
                if !moved && mayRetry {
                    retried = true
                    NSApp.activate()
                    try? await Task.sleep(for: .milliseconds(300))
                    _ = SpaceSwitcher.switchTo(desktop: number)
                    try? await Task.sleep(for: .milliseconds(900))
                    self.refresh()
                    moved = self.snapshot.activeSpaceID != startingSpace
                }
                let outcome = moved ? "switched"
                    : mayRetry ? "macOS did not switch"
                    : "macOS did not switch (no retry: \(frontName) isn't an app known to block the shortcuts)"
                self.lastSwitchReport = "Desktop \(number): pressed \(shortcut.symbol) while \(frontName) was in front"
                    + (retried ? ", then again with SpaceKeeper in front" : "") + " → \(outcome)"
                self.statusMessage = moved ? nil
                    : "SpaceKeeper pressed \(shortcut.symbol) but macOS didn't switch. Check that “Switch to Desktop \(number)” is ticked in Keyboard Shortcuts › Mission Control, and that pressing \(shortcut.symbol) yourself works."
            }
        }
    }

    /// Desktops (up to 16) whose "Switch to Desktop" shortcut is off.
    var desktopsWithoutShortcuts: [Int] {
        snapshot.allSpaces.compactMap(\.desktopNumber)
            .filter { $0 <= SpaceSwitcher.maxDesktop }
            .filter { SpaceSwitcher.shortcutState(forDesktop: $0) == .off }
    }

    func turnOnDesktopShortcuts() {
        let count = snapshot.allSpaces.compactMap(\.desktopNumber).max() ?? 1
        let changed = SpaceSwitcher.enableDesktopShortcuts(upTo: count)
        statusMessage = changed > 0
            ? "Turned on \(changed) “Switch to Desktop” shortcut\(changed == 1 ? "" : "s"). Try a jump arrow."
            : "Couldn't change the shortcuts. Turn them on in System Settings › Keyboard › Keyboard Shortcuts › Mission Control."
        refresh(force: true)
    }

    // The text shown under "Diagnostics" in the panel. Each line checks one
    // thing that a feature depends on, to make problems easy to track down.
    /// Plain-text report of everything switching depends on.
    var diagnosticsReport: String {
        let desktops = snapshot.allSpaces.compactMap(\.desktopNumber).filter { $0 <= SpaceSwitcher.maxDesktop }
        let shortcuts = (desktops.isEmpty ? [1, 2] : desktops)
            .map { "  Desktop \($0): \(SpaceSwitcher.shortcutState(forDesktop: $0).summary)" }
            .joined(separator: "\n")
        return """
        Accessibility: \(accessibilityTrusted ? "allowed" : "NOT allowed")
        Signed by: \(Diagnostics.signature)
        App: \(Diagnostics.appPath)
        Shortcuts:
        \(shortcuts)
        Last switch: \(lastSwitchReport)
        Open shortcut double-tap ⌃: \(doubleTap.status); used \(doubleTap.pressCount)×
        Open shortcut ⌃⌥S: \(openHotKey.status); pressed \(openHotKey.pressCount)×
        Quick panel: \(quickPanel?.lastResult ?? "not set up")
        Add desktop: \(MissionControl.lastAddReport)
        """
    }

    func requestAccessibility() {
        SpaceSwitcher.requestTrust()
        SystemUI.openAccessibilitySettings()
    }

    // --- SETTINGS ------------------------------------------------------------
    // Each setting appears here as a property with `get` (read the value) and
    // `set` (save the new value). SwiftUI switches and pickers in the panel are
    // "bound" to these, so flipping a switch calls `set` automatically, which
    // saves the settings and refreshes anything that depends on them.
    // MARK: Settings (bindable)

    var showHUD: Bool {
        get { settings.showHUD }
        set { updateSettings { $0.showHUD = newValue } }
    }

    var showNameInMenuBar: Bool {
        get { settings.showNameInMenuBar }
        set { updateSettings { $0.showNameInMenuBar = newValue } }
    }

    var showDesktopLabels: Bool {
        get { settings.showDesktopLabels }
        set { updateSettings { $0.showDesktopLabels = newValue } }
    }

    var labelCorner: LabelCorner {
        get { settings.labelCorner }
        set { updateSettings { $0.labelCorner = newValue } }
    }

    var labelLayer: LabelLayer {
        get { settings.labelLayer }
        set { updateSettings { $0.labelLayer = newValue } }
    }

    /// Open the panel by double-tapping Control (or ⌃⌥S). (The setting keeps its old name so saved settings still load.)
    var openWithModifierTap: Bool {
        get { settings.openWithModifierTap }
        set {
            updateSettings { $0.openWithModifierTap = newValue }
            if newValue && !SpaceSwitcher.isTrusted { SpaceSwitcher.requestTrust() }
            updateOpenShortcut()
        }
    }

    private func updateOpenShortcut() {
        if settings.openWithModifierTap {
            doubleTap.start()        // double-tap Control (main, one-handed)
            openHotKey.register()    // ⌃⌥S (for keyboards without fn)
        } else {
            doubleTap.stop()
            openHotKey.unregister()
        }
    }

    var notifyPinMoves: Bool {
        get { settings.notifyPinMoves }
        set { updateSettings { $0.notifyPinMoves = newValue } }
    }

    /// Text and icon size of the panel (see PanelTextSize in Models.swift).
    var panelTextSize: PanelTextSize {
        get { settings.panelTextSize }
        set { updateSettings { $0.panelTextSize = newValue } }
    }

    var overlayTextSize: OverlayTextSize {
        get { settings.overlayTextSize }
        set { updateSettings { $0.overlayTextSize = newValue } }
    }

    var labelOpacity: Double {
        get { settings.labelOpacity }
        set { updateSettings { $0.labelOpacity = newValue } }
    }

    var launchAtLogin: Bool {
        get { launchAtLoginEnabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                statusMessage = "Couldn't change the login item: \(error.localizedDescription)"
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    // --- HELPERS -------------------------------------------------------------
    // updateConfig / updateSettings: change saved data AND write it to disk in
    // one step, so nothing is forgotten. syncLabels: redraw desktop labels.
    // MARK: Helpers

    private func updateConfig(_ key: String, _ body: (inout SpaceConfig) -> Void) {
        var config = configs[key] ?? SpaceConfig()
        body(&config)
        configs[key] = config.isEmpty ? nil : config
        Persistence.save(configs)
    }

    private func updateSettings(_ body: (inout AppSettings) -> Void) {
        body(&settings)
        Persistence.save(settings)
        syncLabels()
    }

    private func syncLabels() {
        labels.sync(snapshot: snapshot, settings: settings) { displayName(for: $0) }
    }
}
