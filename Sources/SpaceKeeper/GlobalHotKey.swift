// ======================================================================
// GlobalHotKey.swift — the ⌃⌥S keyboard shortcut
// ======================================================================
// Registers a system-wide shortcut with macOS's own hotkey service
// ("Carbon" is the name of the older Mac framework that provides it — it's
// still the standard way to do this). It works whichever app is in front
// and needs no special permission.
//
// Connected in AppModel.start(): `onPress` is set to open/close the quick
// panel (QuickPanelController in OpenShortcut.swift). Turned on and off by
// the "Open SpaceKeeper with ⌃⌥S" setting (AppModel.openWithModifierTap).
// ======================================================================

import AppKit
import Carbon.HIToolbox

/// A standard system-wide keyboard shortcut (⌃⌥S by default), registered with
/// macOS's own hotkey service. It works whichever app is in front and needs no
/// extra permission.
final class GlobalHotKey {
    var onPress: () -> Void = {}

    /// For Diagnostics.
    private(set) var status = "off"
    private(set) var pressCount = 0

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    // Two steps: (1) install a handler that macOS calls when ANY of our
    // hotkeys is pressed, (2) register the actual key combination. If another
    // app already owns ⌃⌥S, registration fails and the Diagnostics report says so.
    func register(keyCode: Int = kVK_ANSI_S, modifiers: Int = controlKey | optionKey) {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                hotKey.pressCount += 1
                hotKey.onPress()
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x534B_5052), id: 1) // "SKPR"
        let error = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                        GetApplicationEventTarget(), 0, &hotKeyRef)
        status = error == noErr
            ? "registered"
            : "couldn't register — another app may already use ⌃⌥S (error \(error))"
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        status = "off"
    }
}
