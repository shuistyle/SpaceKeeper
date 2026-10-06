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
//   StatusItemController.swift  the menu bar icon (click → panel)
//   OpenShortcut.swift     ⌃⌥ tap detection + the floating panel (desktop grid)
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

// The app itself.
// SpaceKeeper has no ordinary windows: its menu bar icon is created by
// StatusItemController and its panel by QuickPanelController. SwiftUI
// still needs at least one "scene", so we declare an empty Settings scene.
@main
struct SpaceKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// The AppDelegate is an older-style (AppKit) helper that macOS calls at
// key moments, e.g. "the app has finished launching". We use it to own the
// AppModel and to start it up once the app is ready.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var model = AppModel()
    private var statusItem: StatusItemController?

    // Runs once at launch: hide the Dock icon (this is a menu-bar-only app)
    // and start the model (AppModel.start() begins watching your Spaces).
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        model.start()
        statusItem = StatusItemController(model: model)
    }
}
