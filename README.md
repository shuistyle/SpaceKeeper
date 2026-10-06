# SpaceKeeper

A menu bar utility for macOS 26+ (tested target: macOS 27) that lets you **name your Spaces** and **pin Spaces in place**. Built in Swift 6.2 with SwiftUI, Observation and Liquid Glass. It works on a standard Mac and does **not** need System Integrity Protection disabled.

## What it does

| Feature | How it works |
|---|---|
| **See all desktops at once** | Click the menu bar icon (or double-tap Control): your desktops appear as tiles centred at the top of the screen, like Mission Control's strip. Up to 16 desktops fit as 2 rows of 8 (4 columns at the larger text sizes), so there's no scrolling. Click a tile to jump; drag tiles to reorder. |
| **Name each desktop** | Double-click a tile (or right-click › Rename, or ⌘R) and type a name. Names are tied to the Space's internal UUID, so they survive reboots and reordering. |
| **Current name in the menu bar** | The menu bar shows the name of the Space you're on. |
| **Switch HUD** | A Liquid Glass banner shows the name each time you change Space. |
| **Desktop labels** | A small name tag sits in a corner of each desktop. Because the tag lives *on* that desktop, it also shows in the desktop's thumbnail in Mission Control. |
| **Keep Spaces in a fixed order** | One switch turns off macOS's "Automatically rearrange Spaces based on most recent use" (the main reason Spaces move), then restarts the Dock. |
| **Pin a Space** | Click the pin to record a Space's position. If it moves (dragged in Mission Control, or moved to another display), you get a notification and a warning in the panel, with "Open Mission Control", "Pin Here" and "Unpin". |
| **Jump to a Space** | The arrow button presses Control-1…Control-0 for you. |

## What macOS doesn't allow (without disabling SIP)

- **Changing the "Desktop 1, Desktop 2…" text in Mission Control's top bar.** That text is drawn by the Dock, and only code injected into the Dock can change it. The desktop labels are the SIP-safe alternative.
- **Moving a Space back automatically.** No public or read-only API reorders Spaces. SpaceKeeper stops macOS moving them (fixed order) and tells you when a pinned Space has moved anyway.

## Build & install

You need Xcode 26 or later (or its Command Line Tools).

```bash
cd SpaceKeeper
./build.sh --install     # builds, signs, copies to ~/Applications, launches
```

Or open `Package.swift` in Xcode to edit and debug. Note: notifications and "Launch at login" only work from the bundled `.app` that `build.sh` makes.

### First run

1. Click the stacked-squares icon in the menu bar.
2. Turn on **Keep Spaces in a fixed order** (the Dock restarts once).
3. Name your desktops and pin the ones that matter.
4. To use the jump buttons:
   - Click **Enable Switching…** and allow SpaceKeeper under *Privacy & Security › Accessibility*.
   - In *System Settings › Keyboard › Keyboard Shortcuts › Mission Control*, turn on **Switch to Desktop 1…N**.
5. Optional: turn on **Launch at login**.

### Signing

macOS links the Accessibility permission to the app's signature. The first time `build.sh` runs, it creates a self-signed certificate called **SpaceKeeper Local Signing** in your login keychain. It then signs every build with it, so the permission survives rebuilds. If you have an Apple Development certificate, it uses that instead.

On that first signed build, the script clears the old permission. Click **Enable Switching…** once, turn SpaceKeeper on, then quit and reopen it.

## Accessibility

SpaceKeeper is built to work with macOS's accessibility features:

- **VoiceOver:** every button says what it does and which desktop it acts on ("Pin Outlook", "Switch to Mail"). Each desktop row reads as one summary ("Outlook, Desktop 1, current, pinned"). Desktop switches, pin warnings and status messages are announced. The on-screen labels and switch banner are decorative and hidden from VoiceOver, because the same information is spoken.
- **Keyboard only:** Double-tap Control (one-handed; or ⌃⌥S) opens the panel with the current desktop focused. Arrow keys move between tiles, Return jumps, 1–9 and 0 jump straight to Desktops 1–10, ⌘R renames, ⌥⌘ + arrows reorder, ⌘⌫ removes, ⌘N adds and Esc closes. With VoiceOver, Rename, Pin, Move and Remove are in each tile's Actions menu (VO-Command-Space).
- **Vision:** the panel has its own **Text size** setting (Standard, Large, Extra large, Largest = 200 %). Change it with the **A / A** buttons at the bottom of the panel, or with ⌘+ / ⌘− / ⌘0. Text, icons and click targets all grow, and the smallest text is 12 pt even at Standard. Helper text uses a darker grey for about 7:1 contrast. The label and banner text size can be Standard, Large or Extra large. With **Reduce Transparency** or **Increase Contrast** turned on, labels and banners get a solid, bordered background, and labels can't drop below 95% opacity. Warnings use shapes as well as colour (warning triangle, crossed-out pin), and the current desktop has a ring as well as a fill.
- **Motion:** with **Reduce Motion** turned on, reordering doesn't animate and the banner doesn't fade.
- **Targets:** icon buttons have at least 24 × 24 point click areas.

## Tips

- If desktop labels appear on every Space instead of just one, set **Layer** to *Above windows*.
- A label is created the first time you visit each desktop after launch. Visit each Space once and they'll all be tagged, including in Mission Control's thumbnails.
- Full-screen app Spaces are listed but can't be renamed or pinned, because macOS gives them a new identity each time.

## Reading the code

Every file starts with a plain-English header explaining what it does and which files it talks to, and each main section has a short explainer. New to Swift? Start with **Sources/SpaceKeeper/SpaceKeeperApp.swift**. It has a map of the whole app and a glossary of the terms used in the comments. Then read **AppModel.swift**, "the brain", which every other part connects to.

## Project layout

```
Package.swift                 Swift 6.2, macOS 26+, MainActor-by-default
Sources/CGSPrivate/           C bridge: read-only CGS Spaces calls + display UUID helper
Sources/SpaceKeeper/
  SpaceKeeperApp.swift        @main, MenuBarExtra, AppDelegate, menu bar label
  AppModel.swift              @Observable state: polling, names, pins, alerts, settings
  SpaceReader.swift           Turns window-server data into SpaceSnapshot
  Models.swift                Value types, settings, persistence
  SystemBridges.swift         Dock "mru-spaces" pref, Control-N switching, System Settings links
  Overlays.swift              Switch HUD + per-desktop label windows
  Views/MenuPanelView.swift   The menu bar panel UI
Resources/Info.plist          LSUIElement (no Dock icon)
build.sh                      Build → .app → codesign → install
```

## Private API note

SpaceKeeper uses three private, **read-only** calls (`CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`). Many long-running utilities use them, but Apple could change them in a future macOS. That rules out the Mac App Store, but it's fine for personal use or Developer ID distribution. If the panel ever says it "couldn't read your Spaces", a macOS update has changed them.
