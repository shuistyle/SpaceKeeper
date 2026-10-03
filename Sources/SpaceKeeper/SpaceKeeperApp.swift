// ======================================================================
// SpaceKeeperApp.swift — START HERE
// ======================================================================
// This is the front door of the app: macOS runs the code marked `@main`
// first. Read this file first, then follow the links below.
//
// HOW THE APP FITS TOGETHER (a map of the files)
//
//   SpaceKeeperApp.swift  (this file)
//       Creates the menu bar icon and the panel that drops down from it.
//       Creates ONE AppModel and hands it to every screen.
//           │
//           ▼
//   AppModel.swift  — the "brain". Holds everything the app knows
//       (your Spaces, their names, pins, settings) and every action
//       (rename, pin, switch, add, remove…). Screens read from it and
//       call it; they never talk to macOS directly.
//           │ asks for data / sends commands to …
//           ▼
//   SpaceReader.swift      reads the current list of Spaces from macOS
//   SystemBridges.swift    Dock setting, desktop switching, diagnostics,
//                          accessibility helpers
//   MissionControl.swift   adds/removes desktops by driving Mission Control
//   Overlays.swift         the switch banner (HUD) and the desktop labels
//   OpenShortcut.swift     ⌃⌥ tap detection + the floating "quick panel"
//   GlobalHotKey.swift     the ⌃⌥S keyboard shortcut
//   Models.swift           the plain data types everything above shares,
//                          and saving/loading them
//   Views/MenuPanelView.swift  everything you see inside the panel
//   ../CGSPrivate/         a tiny C "bridge" to macOS functions that Swift
//                          can't call on its own
//
// GLOSSARY (words used throughout the comments)
//   Space / desktop  One of the virtual screens in Mission Control.
//                    "Space" includes full-screen apps; "desktop" means
//                    an ordinary Space.
//   Display          A physical screen (built-in or external monitor).
//   Snapshot         A picture, taken every 1.5 s, of which Spaces exist
//                    and which one you are on (see SpaceSnapshot).
//   Key              A Space's permanent ID, used to remember its name/pin.
//   View             A piece of on-screen UI written in SwiftUI.
//   Model            The object that holds the app's data (AppModel).
//   MainActor        Swift's rule that UI code runs on the main thread.
//                    Package.swift makes it the default for this app, so
//                    you rarely see it written out.
//   Private API      A macOS function Apple doesn't document. We only use
//                    ones that read information or that System Settings
//                    itself uses. They might change in future macOS updates.
// ======================================================================

import AppKit
import SwiftUI

// The app itself. SwiftUI builds the menu bar item from `body`.
// `MenuBarExtra` = an icon in the menu bar that opens a panel when clicked.
// • The panel's content is MenuPanelView (Views/MenuPanelView.swift).
// • The icon/text in the menu bar is MenuBarLabel (further down this file).
// • `.environment(appDelegate.model)` passes the single AppModel down to
//   every view, so they all share the same data.
@main
struct SpaceKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

// The AppDelegate is an older-style (AppKit) helper that macOS calls at
// key moments, e.g. "the app has finished launching". We use it to own the
// AppModel and to start it up once the app is ready.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var model = AppModel()

    // Runs once at launch: hide the Dock icon (this is a menu-bar-only app)
    // and start the model (AppModel.start() begins watching your Spaces).
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        model.start()
    }
}

// What appears in the menu bar itself: an icon, plus the current Space's
// name if "Show name in menu bar" is on. If a pinned desktop has moved
// (AppModel.pinAlerts is not empty) the icon becomes an orange warning
// triangle. `spokenLabel` is what VoiceOver reads for this item.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let name = model.currentSpace.map { model.displayName(for: $0).truncated(to: 24) }
        Group {
            if model.pinAlerts.isEmpty {
                if model.showNameInMenuBar, let name {
                    Text("\(Image(systemName: "square.stack.3d.up.fill")) \(name)")
                } else {
                    Image(systemName: "square.stack.3d.up.fill")
                }
            } else {
                // Shape (a warning triangle) as well as colour marks the problem.
                if model.showNameInMenuBar, let name {
                    Text("\(Image(nsImage: Self.warningIcon)) \(name)")
                } else {
                    Image(nsImage: Self.warningIcon)
                }
            }
        }
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        var text = "SpaceKeeper"
        if let space = model.currentSpace {
            text += ", current Space: \(model.displayName(for: space))"
        }
        if !model.pinAlerts.isEmpty {
            text += ", warning: pinned order changed"
        }
        return text
    }

    private static let warningIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                            accessibilityDescription: "Pinned desktop order changed")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}
