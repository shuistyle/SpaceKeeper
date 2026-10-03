// ======================================================================
// CGSPrivate.c — small C wrappers used by the Swift code
// ======================================================================
// Each SK… function here calls a macOS function and tidies the result so
// Swift can use it safely. Declarations (and who uses them) are in
// include/CGSPrivate.h.
// ======================================================================

#include "CGSPrivate.h"
#include <ApplicationServices/ApplicationServices.h>

CFStringRef SKCopyDisplayUUIDString(uint32_t displayID) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayID);
    if (uuid == NULL) {
        return NULL;
    }
    CFStringRef string = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return string;
}

// Private SkyLight symbols (re-exported by CoreGraphics).
extern bool CGSIsSymbolicHotKeyEnabled(uint32_t hotKey);
extern CGError CGSSetSymbolicHotKeyEnabled(uint32_t hotKey, bool isEnabled);
extern CGError CGSGetSymbolicHotKeyValue(uint32_t hotKey, UniChar *keyEquivalent, UniChar *virtualKeyCode, void *modifiers);
extern CGError CGSSetSymbolicHotKeyValue(uint32_t hotKey, UniChar keyEquivalent, CGKeyCode virtualKeyCode, uint64_t modifiers);

bool SKIsSymbolicHotKeyEnabled(uint32_t hotKey) {
    return CGSIsSymbolicHotKeyEnabled(hotKey);
}

bool SKGetSymbolicHotKey(uint32_t hotKey, uint16_t *character, uint16_t *keyCode, uint64_t *modifiers) {
    UniChar key = 0, code = 0;
    uint64_t mods[2] = {0, 0}; // oversized: the private type's width isn't documented
    if (CGSGetSymbolicHotKeyValue(hotKey, &key, &code, mods) != kCGErrorSuccess) {
        return false;
    }
    *character = key;
    *keyCode = code;
    *modifiers = mods[0] & 0xFFFFFFFFull;
    return true;
}

bool SKSetSymbolicHotKey(uint32_t hotKey, uint16_t character, uint16_t keyCode, uint64_t modifiers, bool enabled) {
    if (CGSSetSymbolicHotKeyValue(hotKey, character, keyCode, modifiers) != kCGErrorSuccess) {
        return false;
    }
    return CGSSetSymbolicHotKeyEnabled(hotKey, enabled) == kCGErrorSuccess;
}
