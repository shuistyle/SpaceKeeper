// ======================================================================
// Views/MenuPanelView.swift — everything you see inside the panel
// ======================================================================
// Written in SwiftUI: you describe WHAT the screen should show, and
// SwiftUI draws it and redraws it whenever the data changes.
//
// It's shown in the floating panel centred at the top of the screen
// (QuickPanelController in OpenShortcut.swift), which opens when you click
// the menu bar icon (StatusItemController.swift) or double-tap Control (or press ⌃⌥S).
//
// Every view here gets the shared AppModel with
//     @Environment(AppModel.self) private var model
// and only ever reads `model` properties or calls `model` functions.
//
// Layout, top to bottom (each is its own small view below):
//   CurrentSpaceHeader → PinAlertsView → AutoRearrangeBanner →
//   ShortcutsBanner → DesktopGridView (one DesktopTile per Space) →
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

// ======================================================================
// TEXT & ICON SIZE (low-vision support)
// ======================================================================
// macOS's built-in text styles are small in menu bar panels (captions are
// 10 pt) and macOS doesn't let menu bar apps follow a system text size. So
// every font and icon in the panel goes through `skFont`, which:
//   • uses larger base sizes than macOS's defaults (12 pt minimum), and
//   • multiplies them by the user's Text size setting (`panelScale`,
//     from PanelTextSize in Models.swift: 1.0 / 1.3 / 1.6 / 2.0).
// Helper text uses `skSecondary`, a darker grey than macOS's .secondary
// (which measures about 4:1 contrast — below the WCAG minimum of 4.5:1).

/// The panel's size multiplier, passed down from MenuPanelView.
/// (`nonisolated` because SwiftUI reads environment keys from any thread.)
nonisolated private struct PanelScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

nonisolated extension EnvironmentValues {
    var panelScale: CGFloat {
        get { self[PanelScaleKey.self] }
        set { self[PanelScaleKey.self] = newValue }
    }
}

/// The panel's text styles, with base point sizes at "Standard".
enum SKTextStyle {
    case caption, callout, body, headline, title3, title, icon, mono

    var baseSize: CGFloat {
        switch self {
        case .caption: 12
        case .callout: 13
        case .body: 14
        case .headline: 15
        case .title3: 18
        case .title: 22
        case .icon: 16
        case .mono: 12
        }
    }

    var defaultWeight: Font.Weight {
        switch self {
        case .headline: .semibold
        case .title: .bold
        default: .regular
        }
    }
}

private struct SKFontModifier: ViewModifier {
    @Environment(\.panelScale) private var scale
    let style: SKTextStyle
    let weight: Font.Weight?
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let size = style.baseSize * scale
        var font = Font.system(size: size, weight: weight ?? style.defaultWeight,
                               design: style == .mono ? .monospaced : .default)
        if monospacedDigit { font = font.monospacedDigit() }
        return content.font(font)
    }
}

/// Picks a control size (buttons, switches, pickers) to match the text size.
private struct SKControlSizeModifier: ViewModifier {
    @Environment(\.panelScale) private var scale

    func body(content: Content) -> some View {
        content.controlSize(scale >= 2 ? .extraLarge : scale > 1 ? .large : .regular)
    }
}

extension View {
    func skFont(_ style: SKTextStyle, weight: Font.Weight? = nil, monospacedDigit: Bool = false) -> some View {
        modifier(SKFontModifier(style: style, weight: weight, monospacedDigit: monospacedDigit))
    }

    func skControlSize() -> some View {
        modifier(SKControlSizeModifier())
    }
}

extension Color {
    /// Helper-text colour: darker than macOS's .secondary so it stays
    /// readable (about 7:1 contrast on a light background).
    static var skSecondary: Color { Color.primary.opacity(0.75) }
}

/// A scroll area that is exactly as tall as its content, up to `maxHeight`.
/// (A plain ScrollView in a menu bar panel collapses to zero height.)
private struct FittedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .scrollIndicators(.automatic)
    }
}

/// Usable screen height, for capping scroll areas so the panel fits on screen.
private var screenHeight: CGFloat {
    (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
}


// The whole panel. Shows banners only when they're relevant (`if …`),
// and announces new status messages to VoiceOver (`.onChange`).
struct MenuPanelView: View {
    @Environment(AppModel.self) private var model

    private var scale: CGFloat { model.panelTextSize.scale }

    /// ⌘+ / ⌘− / ⌘0 change the panel's text size, like zooming in a browser.
    private var textSizeShortcuts: some View {
        ZStack {
            Button("Larger text") { model.panelTextSize = model.panelTextSize.bigger }
                .keyboardShortcut("+", modifiers: .command)
            Button("Larger text") { model.panelTextSize = model.panelTextSize.bigger }
                .keyboardShortcut("=", modifiers: .command)
            Button("Smaller text") { model.panelTextSize = model.panelTextSize.smaller }
                .keyboardShortcut("-", modifiers: .command)
            Button("Standard text size") { model.panelTextSize = .standard }
                .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

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

            DesktopGridView()

            Divider()
            SettingsSection()

            if let message = model.statusMessage {
                Text(message)
                    .skFont(.caption)
                    .foregroundStyle(Color.skSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Status: \(message)")
            }

            DiagnosticsView()

            Divider()
            FooterView()
        }
        .padding(GridMetrics.padding(scale))
        // As wide as the desktop grid (2 rows of 8, or 4 columns at large sizes).
        .frame(width: GridMetrics.panelWidth(scale, columns: GridMetrics.columns(scale)))
        // Everything inside reads this to size its text and icons.
        .environment(\.panelScale, scale)
        // Base font for buttons, switches and text fields.
        .font(.system(size: SKTextStyle.body.baseSize * scale))
        .skControlSize()
        .background { textSizeShortcuts }
        .onAppear { model.panelDidAppear() }
        .onChange(of: model.panelTextSize) { _, size in
            A11y.announce("Text size: \(size.title)")
        }
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
    @Environment(\.panelScale) private var scale
    let systemImage: String
    let label: String
    var help: String?
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .skFont(.icon, weight: .medium)
                .foregroundStyle(tint ?? .primary)
                .frame(minWidth: 28 * scale, minHeight: 28 * scale)
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
            .skFont(.headline)
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
                    .skFont(.caption)
                    .foregroundStyle(Color.skSecondary)
                Text(model.currentSpace.map { model.displayName(for: $0) } ?? "Unknown")
                    .skFont(.title)
                    .lineLimit(1)
                if let space = model.currentSpace {
                    Text("\(space.defaultName) · \(space.displayName)")
                        .skFont(.caption)
                        .foregroundStyle(Color.skSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer()
            IconButton(systemImage: "rectangle.3.group", label: "Open Mission Control") {
                SystemUI.openMissionControl()
            }
            .skFont(.title3)
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
                    .skFont(.callout, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if model.pinAlerts.contains(where: \.isMoved) {
                        Button("Accept New Order") { model.acceptCurrentOrder() }
                            .help("Keep the desktops where they are now and save this as the pinned order.")
                    }
                }
                .skControlSize()

                ForEach(model.pinAlerts) { alert in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title)
                                .skFont(.caption, weight: .semibold)
                            Text(alert.message)
                                .skFont(.caption)
                                .foregroundStyle(Color.skSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 4)
                        Button("Unpin") { model.unpin(key: alert.key) }
                            .skControlSize()
                            .accessibilityLabel("Unpin \(alert.name)")
                    }
                }

                if model.pinAlerts.contains(where: \.isMoved) {
                    Button("Open Mission Control to drag it back") { SystemUI.openMissionControl() }
                        .buttonStyle(.link)
                        .skFont(.caption)
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
                    .foregroundStyle(Color.skSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS is rearranging Spaces by recent use.")
                        .skFont(.caption, weight: .semibold)
                    Text("Lock the order so every Space stays where you put it.")
                        .skFont(.caption)
                        .foregroundStyle(Color.skSecondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                Button("Lock Order") { model.setAutoRearrange(false) }
                    .skControlSize()
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
                    .foregroundStyle(Color.skSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Desktop shortcuts are off")
                        .skFont(.caption, weight: .semibold)
                    Text("Jumping needs macOS’s “Switch to Desktop” shortcuts: ⌃1…⌃0 for Desktops 1–10, ⌃⌥1…⌃⌥6 for 11–16.")
                        .skFont(.caption)
                        .foregroundStyle(Color.skSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                Button("Turn On Shortcuts") { model.turnOnDesktopShortcuts() }
                    .skControlSize()
            }
        }
    }
}

// MARK: - Spaces list

// --- THE DESKTOP GRID ------------------------------------------------------
// Desktops appear as tiles, like Mission Control's strip: 2 rows of 8 for
// up to 16 desktops (macOS's maximum per display). At the larger text
// sizes, 8 tiles would be wider than the screen, so the grid switches to
// 4 columns. Either way every desktop is visible at once, so no scrolling.
//
//   Mouse:     click = jump · double-click = rename · drag = reorder ·
//              right-click = Pin, Rename, Move, Remove
//   Keyboard:  arrows move between tiles · Return/Space = jump ·
//              1–9, 0 = jump to that desktop number · ⌘R = rename ·
//              ⌥⌘ + arrows = reorder · ⌘⌫ = remove
//   VoiceOver: each tile is one button ("Mail, Desktop 2, pinned");
//              Rename/Pin/Move/Remove are in its Actions menu.

/// Tile sizes and how many columns fit. Everything scales with Text size.
enum GridMetrics {
    static func tileWidth(_ scale: CGFloat) -> CGFloat { 100 * scale }
    static func tileHeight(_ scale: CGFloat) -> CGFloat { 86 * scale }
    static func gap(_ scale: CGFloat) -> CGFloat { 8 * scale }
    static func padding(_ scale: CGFloat) -> CGFloat { 14 * scale }

    /// 8 columns (two rows of 8) if that fits on screen, otherwise 4.
    static func columns(_ scale: CGFloat) -> Int {
        panelWidth(scale, columns: 8) <= screenWidth * 0.94 ? 8 : 4
    }

    static func panelWidth(_ scale: CGFloat, columns: Int) -> CGFloat {
        CGFloat(columns) * tileWidth(scale) + CGFloat(columns - 1) * gap(scale) + 2 * padding(scale)
    }
}

/// Usable screen width, used to decide between 8 and 4 columns.
private var screenWidth: CGFloat {
    (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.width ?? 1440
}

private struct DesktopGridView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.panelScale) private var scale
    @FocusState private var focusedKey: String?

    private var columns: Int { GridMetrics.columns(scale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            header

            ForEach(model.snapshot.displays) { display in
                let spaces = model.orderedSpaces(for: display)
                VStack(alignment: .leading, spacing: 6 * scale) {
                    if model.snapshot.displays.count > 1 || model.hasCustomOrder(display) {
                        HStack {
                            if model.snapshot.displays.count > 1 {
                                Label(display.name, systemImage: "display")
                                    .skFont(.caption, weight: .semibold)
                                    .foregroundStyle(Color.skSecondary)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            Spacer()
                            if model.hasCustomOrder(display) {
                                Button("Reset to Mission Control Order") { model.resetOrder(for: display) }
                                    .buttonStyle(.link)
                                    .skFont(.caption)
                                    .help("Your tile order is your own; Mission Control isn't changed. This puts the tiles back in Mission Control's order.")
                            }
                        }
                    }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(GridMetrics.tileWidth(scale)), spacing: GridMetrics.gap(scale)),
                                       count: columns),
                        alignment: .leading,
                        spacing: GridMetrics.gap(scale)
                    ) {
                        ForEach(spaces) { space in
                            DesktopTile(
                                space: space,
                                isCurrent: space.managedID == display.currentSpaceID,
                                columns: columns,
                                focusedKey: $focusedKey,
                                moveFocus: { offset in moveFocus(from: space, by: offset, in: spaces) }
                            )
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(model.snapshot.displays.count > 1 ? "Desktops on \(display.name)" : "Desktops")
            }

            if model.snapshot.displays.isEmpty {
                Text("SpaceKeeper couldn't read your Spaces.")
                    .skFont(.callout)
                    .foregroundStyle(Color.skSecondary)
            }
        }
        // 1–9 and 0 jump straight to Desktop 1–10 (when no name is being edited).
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard model.renamingKey == nil, press.modifiers.isEmpty,
                  let digit = Int(press.characters) else { return .ignored }
            let number = digit == 0 ? 10 : digit
            guard let space = model.snapshot.allSpaces.first(where: { $0.desktopNumber == number }) else { return .ignored }
            model.jump(to: space)
            return .handled
        }
        // Each time the panel opens, put keyboard focus on the current desktop.
        .onChange(of: model.panelOpenCount, initial: true) {
            Task {
                try? await Task.sleep(for: .milliseconds(50)) // let the panel appear first
                focusedKey = model.currentSpace?.key ?? model.snapshot.allSpaces.first?.key
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12 * scale) {
            SectionHeading(title: "Desktops")
            Text("Click to jump · double-click to rename · drag to reorder")
                .skFont(.caption)
                .foregroundStyle(Color.skSecondary)
                .lineLimit(2)
                .accessibilityHidden(true) // the same guidance is in each tile's hint
            Spacer()
            // At the macOS limit of 16, say so in words (not just a greyed-out button).
            if model.isAtDesktopLimit {
                Text("\(AppModel.maxDesktopsPerDisplay) of \(AppModel.maxDesktopsPerDisplay) desktops — the macOS maximum")
                    .skFont(.caption, weight: .semibold)
                    .foregroundStyle(Color.skSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true) // spoken as part of the button's hint
            }
            Button {
                model.addDesktop()
            } label: {
                Label {
                    Text("Add Desktop")
                } icon: {
                    if model.isChangingDesktops {
                        ProgressView().skControlSize()
                    } else {
                        Image(systemName: "plus.circle")
                    }
                }
                .skFont(.callout, weight: .medium)
            }
            // Greyed out (and ⌘N does nothing) while busy or at the 16-desktop limit.
            .disabled(!model.canAddDesktop)
            .keyboardShortcut("n", modifiers: .command)
            .help(model.isAtDesktopLimit
                  ? "macOS allows up to \(AppModel.maxDesktopsPerDisplay) desktops. Remove one to add another."
                  : "Add a desktop (⌘N)")
            .accessibilityLabel(model.isChangingDesktops ? "Changing desktops, please wait" : "Add desktop")
            .accessibilityHint(model.isAtDesktopLimit
                               ? "Unavailable: you have \(AppModel.maxDesktopsPerDisplay) desktops, the macOS maximum. Remove one to add another."
                               : "Adds a new desktop at the end.")
        }
    }

    /// Arrow-key navigation: ←/→ move one tile, ↑/↓ move one row.
    private func moveFocus(from space: SpaceInfo, by offset: Int, in spaces: [SpaceInfo]) {
        guard let index = spaces.firstIndex(where: { $0.key == space.key }) else { return }
        let target = index + offset
        guard spaces.indices.contains(target) else { return }
        focusedKey = spaces[target].key
    }
}

/// One desktop tile: number badge, pin marker and name (or a name field while renaming).
private struct DesktopTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.panelScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    let space: SpaceInfo
    let isCurrent: Bool
    let columns: Int
    var focusedKey: FocusState<String?>.Binding
    let moveFocus: (Int) -> Void

    @State private var isHovering = false
    @State private var isDropTarget = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    private var name: String { model.displayName(for: space) }
    private var isDesktop: Bool { space.kind == .desktop }
    private var isPinned: Bool { model.isPinned(space) }
    private var isOutOfOrder: Bool { model.alert(for: space) != nil }
    private var isRenaming: Bool { model.renamingKey == space.key }
    private var isConfirmingRemove: Bool { model.pendingRemovalKey == space.key }
    private var isFocused: Bool { focusedKey.wrappedValue == space.key }
    private var corner: CGFloat { 10 * scale }

    // Colour (optional; DesktopColor in Models.swift). A coloured tile is filled
    // with its colour and uses black or white text chosen for at least 7:1
    // contrast; uncoloured tiles keep the normal light/dark-mode look.
    private var tileColor: DesktopColor? { isDesktop ? model.color(for: space) : nil }
    private var foreground: Color {
        guard let tileColor else { return Color.primary }
        return tileColor.usesDarkText ? .black : .white
    }

    var body: some View {
        content
            .padding(8 * scale)
            .frame(width: GridMetrics.tileWidth(scale), height: GridMetrics.tileHeight(scale), alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: corner).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(borderColor, lineWidth: borderWidth))
            .overlay(alignment: .leading) {
                // Insertion marker while another tile is dragged over this one.
                if isDropTarget {
                    Capsule().fill(Color.accentColor)
                        .frame(width: 4 * scale)
                        .offset(x: -GridMetrics.gap(scale) / 2 - 2 * scale)
                        .accessibilityHidden(true)
                }
            }
            .overlay { if isConfirmingRemove { removeConfirmation } }
            .contentShape(RoundedRectangle(cornerRadius: corner))
            .onHover { isHovering = $0 }
            .onTapGesture { handleClick() }
            .focusable(!isRenaming)
            .focused(focusedKey, equals: space.key)
            .focusEffectDisabled() // we draw a thicker, clearer focus ring ourselves
            .onKeyPress(phases: .down) { handleKey($0) }
            .contextMenu { menuItems }
            .draggableIf(isDesktop && !isRenaming, key: space.key, preview: name)
            .dropDestination(for: String.self) { keys, _ in
                guard let key = keys.first, isDesktop else { return false }
                withAnimation(reduceMotion ? nil : .snappy) { model.move(key: key, to: space) }
                return true
            } isTargeted: { isDropTarget = $0 && isDesktop }
            .help(isDesktop
                  ? "\(name) — click to jump, double-click to rename, drag to reorder, right-click to choose a colour"
                  : "\(name) — a full-screen app")
            // VoiceOver: one button per tile, with the other actions in its Actions menu.
            .accessibilityElement(children: (isRenaming || isConfirmingRemove) ? .contain : .ignore)
            .accessibilityLabel(summary)
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(isDesktop ? "Jumps to this desktop. More actions are in the Actions menu." : "")
            .accessibilityAction { model.jump(to: space) }
            .accessibilityActions { accessibilityActionItems }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack(spacing: 4 * scale) {
                badge
                // The colour's own symbol, so it never relies on colour alone.
                if let tileColor {
                    Image(systemName: tileColor.symbol)
                        .foregroundStyle(foreground)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                if isOutOfOrder {
                    Image(systemName: "pin.slash.fill").foregroundStyle(tileColor == nil ? Color.orange : foreground)
                } else if isPinned {
                    Image(systemName: "pin.fill").foregroundStyle(tileColor == nil ? Color.accentColor : foreground)
                }
                if !isDesktop {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(Color.skSecondary)
                }
            }
            .skFont(.callout, weight: .semibold)

            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .skFont(.callout)
                    .focused($nameFieldFocused)
                    .accessibilityLabel("Name for \(space.defaultName)")
                    .onSubmit { model.finishRenaming(space, newName: draftName) }
                    .onExitCommand { model.finishRenaming(space, newName: nil) }
                    .onAppear {
                        draftName = model.customName(for: space.key)
                        nameFieldFocused = true
                    }
                    // Stop typing (or pasting) at the 60-character limit.
                    .onChange(of: draftName) { _, newValue in
                        if newValue.count > SpaceConfig.maxNameLength {
                            draftName = String(newValue.prefix(SpaceConfig.maxNameLength))
                        }
                    }
                    .accessibilityHint("Up to \(SpaceConfig.maxNameLength) characters")
                    .onChange(of: nameFieldFocused) { _, focused in
                        // Clicking elsewhere saves the name.
                        if !focused, isRenaming { model.finishRenaming(space, newName: draftName) }
                    }
            } else {
                Text(name)
                    .skFont(.callout, weight: isCurrent ? .semibold : .regular)
                    .foregroundStyle(isDesktop ? foreground : Color.skSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Number badge: the current desktop gets a filled circle AND a ring (not colour alone).
    private var badge: some View {
        Text("\(space.index)")
            .skFont(.caption, weight: .bold, monospacedDigit: true)
            .foregroundStyle(badgeText)
            .frame(minWidth: 24 * scale, minHeight: 24 * scale)
            .background(Circle().fill(badgeFill))
            .overlay { if isCurrent { Circle().strokeBorder(foreground, lineWidth: 1.5) } }
    }

    // On a coloured tile the badge uses the tile's text colour, so it keeps
    // the same strong contrast: current = solid circle with the number cut out.
    private var badgeFill: Color {
        if tileColor != nil { return isCurrent ? foreground : foreground.opacity(0.15) }
        return isCurrent ? Color.accentColor : Color.primary.opacity(0.12)
    }

    private var badgeText: Color {
        if let tileColor, isCurrent { return tileColor.usesDarkText ? .white : .black }
        return isCurrent ? Color.white : foreground
    }

    private var fill: Color {
        if let tileColor {
            let (r, g, b) = tileColor.rgb
            let base = Color(red: r / 255, green: g / 255, blue: b / 255)
            return isHovering ? base.mix(with: tileColor.usesDarkText ? .black : .white, by: 0.12) : base
        }
        if isCurrent { return Color.accentColor.opacity(0.22) }
        return Color.primary.opacity(isHovering ? 0.12 : 0.06)
    }

    /// Focus: a thick black/white ring. Current desktop: an accent-coloured ring.
    /// They differ in thickness and colour, so they're easy to tell apart.
    private var borderColor: Color {
        if isFocused { return Color.primary }
        if isCurrent { return Color.accentColor }
        // Coloured tiles get a visible edge with Increase Contrast, so their
        // shape stands out against the panel too.
        if tileColor != nil { return contrast == .increased ? Color.primary : Color.primary.opacity(0.25) }
        return Color.primary.opacity(0.2)
    }

    private var borderWidth: CGFloat {
        if isFocused { return max(3, 3 * scale) }
        if isCurrent { return max(2, 2 * scale) }
        return 1
    }

    private var removeConfirmation: some View {
        VStack(spacing: 4 * scale) {
            Text("Remove?").skFont(.caption, weight: .semibold)
            Button("Remove", role: .destructive) { model.removeDesktop(space) }
                .accessibilityLabel("Confirm remove \(name)")
            Button("Cancel") { model.cancelRemoval() }
                .accessibilityLabel("Cancel removing \(name)")
        }
        .skControlSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: corner))
    }

    // MARK: Actions

    private func handleClick() {
        guard !isRenaming, !isConfirmingRemove else { return }
        focusedKey.wrappedValue = space.key
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            model.startRenaming(space) // second click of a double-click
        } else {
            model.jump(to: space, waitForDoubleClick: isDesktop)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !isRenaming else { return .ignored }
        let reorder = press.modifiers.contains(.command) && press.modifiers.contains(.option)
        switch press.key {
        case .return, .space:
            model.jump(to: space)
        case .leftArrow:
            reorder ? move(by: -1) : moveFocus(-1)
        case .rightArrow:
            reorder ? move(by: 1) : moveFocus(1)
        case .upArrow:
            reorder ? move(by: -columns) : moveFocus(-columns)
        case .downArrow:
            reorder ? move(by: columns) : moveFocus(columns)
        case .delete where press.modifiers.contains(.command):
            if model.canRemove(space) { model.requestRemoval(of: space) }
        default:
            if press.modifiers.contains(.command), press.characters.lowercased() == "r" {
                model.startRenaming(space)
            } else {
                return .ignored
            }
        }
        return .handled
    }

    /// Moves the tile earlier (negative) or later (positive) in your order, one step at a time.
    private func move(by steps: Int) {
        let direction = steps < 0 ? -1 : 1
        var moved = 0
        withAnimation(reduceMotion ? nil : .snappy) {
            for _ in 0..<abs(steps) where model.canMove(space, by: direction) {
                model.move(space, by: direction)
                moved += 1
            }
        }
        if moved > 0 { A11y.announce("Moved \(name) \(direction < 0 ? "earlier" : "later")") }
        focusedKey.wrappedValue = space.key
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Jump to \(name)") { model.jump(to: space) }
            .disabled(isCurrent || !model.canSwitch(to: space))
        Button("Rename…") { model.startRenaming(space) }
            .disabled(!isDesktop)
        Button(isPinned ? "Unpin" : "Pin") { model.togglePin(space) }
            .disabled(!isDesktop)
        if isDesktop {
            // Each colour is listed with its symbol and name.
            Picker("Colour", selection: Binding(
                get: { model.color(for: space) },
                set: { model.setColor($0, for: space) }
            )) {
                Text("None").tag(DesktopColor?.none)
                ForEach(DesktopColor.allCases) { color in
                    Label(color.name, systemImage: color.symbol).tag(DesktopColor?.some(color))
                }
            }
        }
        Divider()
        Button("Move Earlier") { move(by: -1) }
            .disabled(!model.canMove(space, by: -1))
        Button("Move Later") { move(by: 1) }
            .disabled(!model.canMove(space, by: 1))
        Divider()
        Button("Remove Desktop…", role: .destructive) { model.requestRemoval(of: space) }
            .disabled(!model.canRemove(space))
    }

    @ViewBuilder
    private var accessibilityActionItems: some View {
        if isDesktop {
            Button("Rename") { model.startRenaming(space) }
            Button(isPinned ? "Unpin" : "Pin") { model.togglePin(space) }
            // Steps through the colours, announcing each one ("Navy", "no colour"…).
            Button("Change colour") { model.cycleColor(for: space) }
        }
        if model.canMove(space, by: -1) { Button("Move earlier") { move(by: -1) } }
        if model.canMove(space, by: 1) { Button("Move later") { move(by: 1) } }
        if model.canRemove(space) { Button("Remove") { model.requestRemoval(of: space) } }
    }

    private var summary: String {
        var parts = [name]
        if name != space.defaultName { parts.append(space.defaultName) }
        if !isDesktop { parts.append("full-screen app") }
        if isCurrent { parts.append("current") }
        if isPinned { parts.append("pinned") }
        if let tileColor { parts.append("colour \(tileColor.name)") }
        if isOutOfOrder { parts.append("out of pinned order") }
        return parts.joined(separator: ", ")
    }
}

// --- SETTINGS -------------------------------------------------------------
// Collapsed by default: clicking the "Settings" heading shows or hides the
// options (isExpanded). Each SettingRow shows a label on the left and a control on the right.
// `$model.something` binds the control to an AppModel setting, so changing
// the control saves the setting immediately (see "Settings" in AppModel).
private struct SettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.panelScale) private var scale
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
                        .skFont(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .skFont(.caption, weight: .semibold)
                        .foregroundStyle(Color.skSecondary)
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
                // Scrolls if the settings don't fit on screen (e.g. at the largest text size).
                FittedScroll(maxHeight: screenHeight * 0.4) {
                    // Two columns of settings when the panel is wide, one otherwise.
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 32 * scale, alignment: .leading),
                                       count: GridMetrics.columns(scale) == 8 ? 2 : 1),
                        alignment: .leading,
                        spacing: 8 * scale
                    ) {

                        SettingRow("Text size") {
                            Picker("Panel text size", selection: $model.panelTextSize) {
                                ForEach(PanelTextSize.allCases) { Text($0.title).tag($0) }
                            }
                            .fixedSize()
                        }
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
                                .frame(width: 150 * scale)
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

                        SettingRow("Open with double-tap ⌃ (or ⌃⌥S)") {
                            Toggle("Open SpaceKeeper by double-tapping Control, or with Control Option S", isOn: $model.openWithModifierTap)
                        }
                        .help("Tap Control twice quickly (or press Control-Option-S) to open or close SpaceKeeper from any app.")
                        SettingRow("Notify when pinned order changes") {
                            Toggle("Notify when pinned order changes", isOn: $model.notifyPinMoves)
                        }
                        SettingRow("Launch at login") {
                            Toggle("Launch at login", isOn: $model.launchAtLogin)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .toggleStyle(.switch)
        .skControlSize()
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
            // Always-visible text size controls (also ⌘− / ⌘+).
            Button {
                model.panelTextSize = model.panelTextSize.smaller
            } label: {
                Text("A").skFont(.caption, weight: .semibold)
            }
            .disabled(model.panelTextSize == .standard)
            .help("Smaller text (⌘−)")
            .accessibilityLabel("Smaller text")
            .accessibilityValue(model.panelTextSize.title)
            Button {
                model.panelTextSize = model.panelTextSize.bigger
            } label: {
                Text("A").skFont(.title3, weight: .semibold)
            }
            .disabled(model.panelTextSize == .largest)
            .help("Larger text (⌘+)")
            .accessibilityLabel("Larger text")
            .accessibilityValue(model.panelTextSize.title)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .accessibilityLabel("Quit SpaceKeeper")
        }
        .skControlSize()
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
                    .skFont(.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.diagnosticsReport, forType: .string)
                        A11y.announce("Diagnostics report copied")
                    }
                    // Only needed if Add/Remove Desktop stops working after a macOS
                    // update. Window titles are hidden in the map (MissionControl.safeLabel).
                    Button("Save Mission Control Map") {
                        Task {
                            if let url = await MissionControl.saveMapOnRequest() {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                A11y.announce("Mission Control map saved")
                            } else {
                                A11y.announce("Couldn't save the Mission Control map")
                            }
                        }
                    }
                    .help("Opens Mission Control for a moment and saves an outline of its controls, so a problem with Add or Remove Desktop can be diagnosed. Other apps' window titles are hidden.")
                    Button("Delete Map") {
                        MissionControl.deleteMap()
                        A11y.announce("Mission Control map deleted")
                    }
                    .help("Deletes the saved Mission Control map, if there is one.")
                }
                .skControlSize()
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .skFont(.callout)
    }
}

// draggableIf: makes something draggable only when allowed (full-screen
// Spaces can't be reordered). Used by DesktopTile.
private extension View {
    /// Makes the view a drag source for a Space key, only when `enabled`.
    @ViewBuilder
    func draggableIf(_ enabled: Bool, key: String, preview: String) -> some View {
        if enabled {
            draggable(key) {
                Text(preview)
                    .skFont(.callout, weight: .medium)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: .capsule)
            }
        } else {
            self
        }
    }
}
