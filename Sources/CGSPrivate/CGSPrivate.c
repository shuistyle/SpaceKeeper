// ======================================================================
// CGSPrivate.c — small C wrappers used by the Swift code
// ======================================================================
// Each SK… function here calls a macOS function and tidies the result so
// Swift can use it safely. Declarations (and who uses them) are in
// include/CGSPrivate.h.
// ======================================================================

#include "CGSPrivate.h"
#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <string.h>

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

// ----------------------------------------------------------------------
// SKFocusWindow — see CGSPrivate.h.
// The functions are looked up when first needed (dlsym) instead of linked,
// so if a future macOS removes one, SpaceKeeper still starts and simply
// falls back to its other ways of switching.
// ----------------------------------------------------------------------
typedef struct { uint32_t high; uint32_t low; } SKProcessSerialNumber;
typedef OSStatus (*SKGetProcessForPIDFn)(pid_t, SKProcessSerialNumber *);
typedef CGError (*SKSetFrontProcessFn)(SKProcessSerialNumber *, uint32_t, uint32_t);
typedef CGError (*SKPostEventRecordFn)(SKProcessSerialNumber *, uint8_t *);

int SKFocusWindow(int32_t pid, uint32_t windowID) {
    static void *skyLight = NULL;
    if (skyLight == NULL) {
        skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    }
    if (skyLight == NULL) return 1;
    SKSetFrontProcessFn setFront = (SKSetFrontProcessFn)dlsym(skyLight, "_SLPSSetFrontProcessWithOptions");
    SKPostEventRecordFn postEvent = (SKPostEventRecordFn)dlsym(skyLight, "SLPSPostEventRecordTo");
    SKGetProcessForPIDFn getPSN = (SKGetProcessForPIDFn)dlsym(RTLD_DEFAULT, "GetProcessForPID");
    if (setFront == NULL || postEvent == NULL || getPSN == NULL) return 2;

    SKProcessSerialNumber psn = {0, 0};
    if (getPSN(pid, &psn) != 0) return 3;
    // 0x200 = "user generated": treat it as if you'd clicked the window.
    if (setFront(&psn, windowID, 0x200) != kCGErrorSuccess) return 4;

    // Make that window the key window: two small event records, the same
    // ones the window server sends when you click a window.
    uint8_t bytes[0xf8];
    memset(bytes, 0, sizeof bytes);
    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;
    memcpy(&bytes[0x3c], &windowID, sizeof windowID);
    memset(&bytes[0x20], 0xff, 0x10);
    bytes[0x08] = 0x01;
    postEvent(&psn, bytes);
    bytes[0x08] = 0x02;
    postEvent(&psn, bytes);
    return 0;
}
