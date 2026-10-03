// ======================================================================
// Views/MenuPanelView.swift — everything you see inside the panel
// ======================================================================
// Written in SwiftUI: you describe WHAT the screen should show, and
// SwiftUI draws it and redraws it whenever the data changes.
//
// The same MenuPanelView is used in two places:
//   • the menu bar panel  (SpaceKeeperApp.swift)
//   • the ⌃⌥S quick panel  (QuickPanelController in OpenShortcut.swift)
//
// Every view here gets the shared AppModel with
//     @Environment(AppModel.self) private var model
// and only ever reads `model` properties or calls `model` functions.
//
// Layout, top to bottom (each is its own small view below):
//   CurrentSpaceHeader → PinAlertsView → AutoRearrangeBanner →
//   ShortcutsBanner → SpacesListView (one SpaceRow per Space) →
//   SettingsSection → status message → DiagnosticsView → FooterView
//
// SwiftUI words you'll see:
//   some View            "returns some kind of on-screen element"
//   VStack / HStack      stack items vertically / horizontally
//   .modifier(...)       a dot-call after a view changes its look or
//                        behaviour (font, padding, help tooltip…)
//   @State               a value the view remembers between redraws
//   @Bindable / $model.x a two-way link: a switch both shows and changes x
//   .accessibility…      what VoiceOver says and how it can operate it
// ======================================================================

import AppKit
import SwiftUI

// Accessibility notes
// • Every control has a spoken label that names the desktop it acts on.
// • Reordering works without a mouse: VoiceOver actions (Move Up / Move Down)
//   and ⌥⌘↑ / ⌥⌘↓ while a desktop's name field has focus.
// • Status messages and pin warnings are announced to VoiceOver.
// • Honours Reduce Motion, Reduce Transparency, Increase Contrast and
//   Differentiate Without Colour; icon buttons have at least 24 × 24 pt targets.

// The whole panel. Shows banners only when they're relevant (`if …`),
// and announces new status messages to VoiceOver (`.onChange`).
struct MenuPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CurrentSpaceHeader()

            if !model.pinAlerts.isEmpty {
                PinAlertsView()
            }

            if model.autoRearrangeEnabled {
                AutoRearrangeBanner()
            }

            if !model.desktopsWithoutShortcuts.isEmpty {
                ShortcutsBanner()
            }

            SpacesListView()

            Divider()
            SettingsSection()

            if let message = model.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Status: \(message)")
            }

            DiagnosticsView()

            Divider()
            FooterView()
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.panelDidAppear() }
        .onChange(of: model.statusMessage) { _, message in
            if let message { A11y.announce(message) }
        }
    }
}

// MARK: - Shared pieces

// --- SHARED BUILDING BLOCKS -------------------------------------------------
// IconButton: a small image-only button. Every one gets a spoken label for
// VoiceOver and a 24 × 24 point click area, so it's easy to hit.
/// Icon-only button with a spoken label and a comfortable (≥ 24 pt) target.
private struct IconButton: View {
    let systemImage: String
    let label: String
    var help: String?
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(tint ?? .primary)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

// A section title that VoiceOver also treats as a heading (users can jump
// between headings).
private struct SectionHeading: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

// The tinted box used for banners/warnings. With Increase Contrast turned
// on it also gets a border, so it doesn't rely on a faint tint alone.
/// A tinted box for banners and warnings. With Increase Contrast it gets a border.
private struct NoticeBox<Content: View>: View {
    var tint: Color = .secondary
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 10))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(tint, lineWidth: 1.5)
                }
            }
    }
}

// MARK: - Header

// --- HEADER --------------------------------------------------------------
// "Current Space" and its name, plus a button to open Mission Control.
private struct CurrentSpaceHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Current Space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.currentSpace.map { model.displayName(for: $0) } ?? "Unknown")
                    .font(.title2.bold())
                    .lineLimit(1)
                if let space = model.currentSpace {
                    Text("\(space.defaultName) · \(space.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer()
            IconButton(systemImage: "rectangle.3.group", label: "Open Mission Control") {
                SystemUI.openMissionControl()
            }
            .font(.title3)
        }
    }
}

// MARK: - Alerts & banners

// --- WARNINGS AND BANNERS --------------------------------------------------
// The orange box listing pinned desktops that are out of order
// (AppModel.pinAlerts). Buttons call AppModel.acceptCurrentOrder()/unpin().
private struct PinAlertsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NoticeBox(tint: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Icon carries the colour; the text stays high-contrast.
                    Label {
                        Text("Pinned order changed")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if model.pinAlerts.contains(where: \.isMoved) {
                        Button("Accept New Order") { model.acceptCurrentOrder() }
                            .help("Keep the desktops where they are now and save this as the pinned order.")
                    }
                }
                .controlSize(.small)

                ForEach(model.pinAlerts) { alert in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title)
                                .font(.caption.weight(.semibold))
                            Text(alert.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 4)
                        Button("Unpin") { model.unpin(key: alert.key) }
                            .controlSize(.small)
                            .accessibilityLabel("Unpin \(alert.name)")
                    }
                }

                if model.pinAlerts.contains(where: \.isMoved) {
                    Button("Open Mission Control to drag it back") { SystemUI.openMissionControl() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }
}

// Shown while macOS's "rearrange Spaces automatically" is on; one click
// turns it off (AppModel.setAutoRearrange).
private struct AutoRearrangeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NoticeBox {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shuffle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS is rearranging Spaces by recent use.")
                        .font(.caption.weight(.semibold))
                    Text("Lock the order so every Space stays where you put it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                Button("Lock Order") { model.setAutoRearrange(false) }
                    .controlSize(.small)
            }
        }
    }
}

// Shown when some "Switch to Desktop" shortcuts are off; one click turns
// them on (AppModel.turnOnDesktopShortcuts).
private struct ShortcutsBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NoticeBox {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Desktop shortcuts are off")
                        .font(.caption.weight(.semibold))
                    Text("Jumping needs macOS’s “Switch to Desktop” shortcuts: ⌃1…⌃0 for Desktops 1–10, ⌃⌥1…⌃⌥6 for 11–16.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                Button("Turn On Shortcuts") { model.turnOnDesktopShortcuts() }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Spaces list

// --- THE SPACES LIST ------------------------------------------------------
// Header row ("Spaces", tip, + button) and a scrolling list with one
// SpaceRow per Space, grouped by display, in your custom order
// (AppModel.orderedSpaces). The scroll area measures its content so it's
// only as tall as needed (up to 360 points).
private struct SpacesListView: View {
    @Environment(AppModel.self) private var model
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeading(title: "Spaces")
                Spacer()
                Text("Type to rename · ≡ or ⌥⌘↑↓ to reorder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityHidden(true) // the same guidance is given as row hints
                Button {
                    model.addDesktop()
                } label: {
                    Group {
                        if model.isChangingDesktops {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "plus.circle")
                        }
                    }
                    .frame(minWidth: 24, minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(model.isChangingDesktops)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a desktop (⌘N)")
                .accessibilityLabel(model.isChangingDesktops ? "Changing desktops, please wait" : "Add desktop")
                .padding(.trailing, 4)
            }
            // A ScrollView in a menu bar window has no natural height, so measure
            // the rows and size the scroll area to fit (capped so the panel stays on screen).
            ScrollView {
                list
                    .padding(.trailing, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 30), 360))
            .scrollIndicators(.automatic)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.snapshot.displays) { display in
                VStack(alignment: .leading, spacing: 6) {
                    if model.snapshot.displays.count > 1 || model.hasCustomOrder(display) {
                        HStack {
                            if model.snapshot.displays.count > 1 {
                                Label(display.name, systemImage: "display")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            Spacer()
                            if model.hasCustomOrder(display) {
                                Button("Reset to Mission Control Order") { model.resetOrder(for: display) }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                    .help("Your list order is your own; Mission Control isn't changed. This puts the list back in Mission Control's order.")
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    ForEach(model.orderedSpaces(for: display)) { space in
                        SpaceRow(space: space, isCurrent: space.managedID == display.currentSpaceID)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(model.snapshot.displays.count > 1 ? "Spaces on \(display.name)" : "Spaces")
            }
            if model.snapshot.displays.isEmpty {
                Text("SpaceKeeper couldn't read your Spaces.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// ONE row: drag handle ≡, number badge, name field, then pin / switch /
// remove buttons. Everything a mouse user can do here is also available
// to keyboard and VoiceOver users:
//   • rename        – type in the name field
//   • reorder       – drag ≡, OR ⌥⌘↑/↓ in the name field, OR the
//                     VoiceOver "Move Up/Move Down" actions, OR right-click
//   • pin/switch/remove – buttons or right-click menu
// The whole row is read by VoiceOver as one summary (rowSummary).
private struct SpaceRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @ScaledMetric(relativeTo: .caption) private var badgeSize: CGFloat = 22

    let space: SpaceInfo
    let isCurrent: Bool

    @State private var isDropTarget = false
    @FocusState private var nameFocused: Bool

    private var name: String { model.displayName(for: space) }
    private var isDesktop: Bool { space.kind == .desktop }
    private var isPinned: Bool { model.isPinned(space) }
    private var isOutOfOrder: Bool { model.alert(for: space) != nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(isDesktop ? Color.secondary : Color.clear)
                .frame(width: 14, height: 24)
                .contentShape(Rectangle())
                .help("Drag to reorder this list, or press ⌥⌘↑ / ⌥⌘↓ while editing the name")
                .accessibilityHidden(true) // reordering is offered as accessibility actions
                .draggableIf(isDesktop, key: space.key, preview: name)

            numberBadge

            if isDesktop {
                TextField(space.defaultName, text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .accessibilityLabel("Name for \(space.defaultName)")
                    .accessibilityHint("Type a name for this desktop. Press Option-Command-Up or Down to move it in the list.")
            } else {
                Label(space.defaultName, systemImage: "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("\(space.defaultName), full-screen app")
            }

            if model.pendingRemovalKey == space.key {
                Button("Remove", role: .destructive) { model.removeDesktop(space) }
                    .controlSize(.small)
                    .help("Close this desktop. Its windows move to another desktop.")
                    .accessibilityLabel("Confirm remove \(name)")
                    .accessibilityHint("Closes this desktop. Its windows move to another desktop.")
                Button("Cancel") { model.cancelRemoval() }
                    .controlSize(.small)
                    .accessibilityLabel("Cancel removing \(name)")
            } else {
                rowButtons
            }
        }
        .padding(.vertical, 1)
        .overlay(alignment: .top) {
            // Insertion marker while another row is dragged over this one.
            if isDropTarget {
                Capsule().fill(Color.accentColor).frame(height: 2).offset(y: -3)
                    .accessibilityHidden(true)
            }
        }
        .background { if nameFocused { moveShortcuts } }
        .dropDestination(for: String.self) { keys, _ in
            guard let key = keys.first, isDesktop else { return false }
            withAnimation(reduceMotion ? nil : .snappy) { model.move(key: key, to: space) }
            return true
        } isTargeted: { isDropTarget = $0 && isDesktop }
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowSummary)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityActions { accessibilityMoveActions }
    }

    // MARK: Pieces

    private var numberBadge: some View {
        Text("\(space.index)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(isCurrent ? Color.white : Color.primary)
            .frame(minWidth: badgeSize, minHeight: badgeSize)
            .background(Circle().fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.18)))
            .overlay {
                // A ring as well as the fill, so "current" isn't shown by colour alone.
                if isCurrent || withoutColor {
                    Circle().strokeBorder(isCurrent ? Color.primary : Color.clear, lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true) // included in the row summary
    }

    @ViewBuilder
    private var rowButtons: some View {
        IconButton(
            systemImage: isOutOfOrder ? "pin.slash.fill" : (isPinned ? "pin.fill" : "pin"),
            label: isPinned ? "Unpin \(name)" : "Pin \(name)",
            help: isPinned ? "Unpin" : "Pin: keep this desktop’s place among your pinned desktops",
            tint: isOutOfOrder ? .orange : (isPinned ? .accentColor : .secondary)
        ) {
            model.togglePin(space)
        }
        .disabled(!isDesktop)

        IconButton(
            systemImage: "arrow.right.circle",
            label: "Switch to \(name)",
            help: space.desktopNumber.map { "Switch to Desktop \($0)" } ?? "Switch to this Space"
        ) {
            model.switchTo(space)
        }
        .disabled(isCurrent || !model.canSwitch(to: space))

        IconButton(systemImage: "minus.circle", label: "Remove \(name)", help: "Remove this desktop") {
            model.requestRemoval(of: space)
        }
        .disabled(!model.canRemove(space))
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Move Up") { move(-1) }
            .disabled(!model.canMove(space, by: -1))
        Button("Move Down") { move(1) }
            .disabled(!model.canMove(space, by: 1))
        Divider()
        Button(isPinned ? "Unpin" : "Pin") { model.togglePin(space) }
            .disabled(!isDesktop)
        Button("Switch to Desktop") { model.switchTo(space) }
            .disabled(isCurrent || !model.canSwitch(to: space))
        Divider()
        Button("Remove Desktop…", role: .destructive) { model.requestRemoval(of: space) }
            .disabled(!model.canRemove(space))
    }

    @ViewBuilder
    private var accessibilityMoveActions: some View {
        if model.canMove(space, by: -1) {
            Button("Move Up") { move(-1) }
        }
        if model.canMove(space, by: 1) {
            Button("Move Down") { move(1) }
        }
    }

    /// ⌥⌘↑ / ⌥⌘↓ while the name field has focus.
    private var moveShortcuts: some View {
        ZStack {
            Button("Move Up") { move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Move Down") { move(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func move(_ offset: Int) {
        guard model.canMove(space, by: offset) else { return }
        withAnimation(reduceMotion ? nil : .snappy) { model.move(space, by: offset) }
        A11y.announce("Moved \(name) \(offset < 0 ? "up" : "down")")
    }

    private var rowSummary: String {
        var parts = [name]
        if name != space.defaultName { parts.append(space.defaultName) }
        if isCurrent { parts.append("current") }
        if isPinned { parts.append("pinned") }
        if isOutOfOrder { parts.append("out of pinned order") }
        return parts.joined(separator: ", ")
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.customName(for: space.key) },
            set: { model.rename(space, to: $0) }
        )
    }
}

// MARK: - Settings & footer

// --- SETTINGS -------------------------------------------------------------
// Collapsed by default: clicking the "Settings" heading shows or hides the
// options (isExpanded). Each SettingRow shows a label on the left and a control on the right.
// `$model.something` binds the control to an AppModel setting, so changing
// the control saves the setting immediately (see "Settings" in AppModel).
private struct SettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Collapsed by default, so the panel opens showing just your desktops.
    // Click "Settings" to show the options; click it again to hide them.
    @State private var isExpanded = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            // The "Settings" heading is a button that shows/hides everything below it.
            Button {
                withAnimation(reduceMotion ? nil : .snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Settings")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help(isExpanded ? "Hide settings" : "Show settings")
            .accessibilityLabel("Settings")
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            .accessibilityHint(isExpanded ? "Hides the settings" : "Shows the settings")
            .accessibilityAddTraits(.isHeader)

            if isExpanded {

                SettingRow("Keep Spaces in a fixed order") {
                    Toggle("Keep Spaces in a fixed order", isOn: $model.keepSpacesInOrder)
                }
                SettingRow("Show name when switching") {
                    Toggle("Show name when switching", isOn: $model.showHUD)
                }
                SettingRow("Show name in menu bar") {
                    Toggle("Show name in menu bar", isOn: $model.showNameInMenuBar)
                }
                SettingRow("Label each desktop") {
                    Toggle("Label each desktop", isOn: $model.showDesktopLabels)
                }

                if model.showDesktopLabels {
                    SettingRow("Corner") {
                        Picker("Label corner", selection: $model.labelCorner) {
                            ForEach(LabelCorner.allCases) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                    }
                    SettingRow("Layer") {
                        Picker("Label layer", selection: $model.labelLayer) {
                            ForEach(LabelLayer.allCases) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                    }
                    SettingRow("Opacity") {
                        Slider(value: $model.labelOpacity, in: 0.3...1, step: 0.05) {
                            Text("Label opacity")
                        }
                        .frame(width: 150)
                        .accessibilityValue("\(Int((model.labelOpacity * 100).rounded())) percent")
                    }
                }

                if model.showDesktopLabels || model.showHUD {
                    SettingRow("Label and banner size") {
                        Picker("Label and banner text size", selection: $model.overlayTextSize) {
                            ForEach(OverlayTextSize.allCases) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                    }
                }

                SettingRow("Open SpaceKeeper with ⌃⌥S") {
                    Toggle("Open SpaceKeeper with Control-Option-S", isOn: $model.openWithModifierTap)
                }
                .help("Press Control-Option-S (or tap Control-Option on its own) to open or close SpaceKeeper from any app.")
                SettingRow("Notify when pinned order changes") {
                    Toggle("Notify when pinned order changes", isOn: $model.notifyPinMoves)
                }
                SettingRow("Launch at login") {
                    Toggle("Launch at login", isOn: $model.launchAtLogin)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// Layout helper for one settings line. The visible label is hidden from
// VoiceOver because the control already carries the same label — this
// stops VoiceOver reading everything twice.
/// Label on the left, control pinned to the right edge (lined up with the row
/// buttons above). The control carries its own label for VoiceOver; the visible
/// text is hidden from it so nothing is read twice.
private struct SettingRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            control
                .labelsHidden()
        }
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: 24)
    }
}

// --- FOOTER, DIAGNOSTICS, HELPERS -----------------------------------------
// Bottom row: permission/shortcut settings button and Quit.
private struct FooterView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            if !model.accessibilityTrusted {
                Button("Enable Switching…") { model.requestAccessibility() }
                    .help("SpaceKeeper needs Accessibility permission to press your Switch to Desktop shortcuts.")
            } else {
                Button("Shortcut Settings…") { SystemUI.openKeyboardShortcuts() }
                    .help("Make sure “Switch to Desktop N” is on under Mission Control.")
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .accessibilityLabel("Quit SpaceKeeper")
        }
        .controlSize(.small)
    }
}

// MARK: - Diagnostics

// Collapsible report (AppModel.diagnosticsReport) with a Copy button —
// useful when something isn't working.
private struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Diagnostics", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.diagnosticsReport)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticsReport, forType: .string)
                    A11y.announce("Diagnostics report copied")
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

// draggableIf: makes something draggable only when allowed (full-screen
// Spaces can't be reordered). Used by SpaceRow's ≡ handle.
private extension View {
    /// Makes the view a drag source for a Space key, only when `enabled`.
    @ViewBuilder
    func draggableIf(_ enabled: Bool, key: String, preview: String) -> some View {
        if enabled {
            draggable(key) {
                Text(preview)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: .capsule)
            }
        } else {
            self
        }
    }
}
