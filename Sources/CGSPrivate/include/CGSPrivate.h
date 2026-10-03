// ======================================================================
// CGSPrivate.h — the C "bridge" to undocumented macOS functions
// ======================================================================
// Swift can call C functions if they are declared in a header like this.
// These functions live inside macOS (in a system framework) but Apple
// doesn't publish them, so we declare them ourselves.
//
// What each group is for, and who uses it:
//   • Spaces (read-only)  → SpaceReader.swift
//   • SKCopyDisplayUUIDString → SpaceReader.swift (match Spaces to screens)
//   • Symbolic hotkeys ("Switch to Desktop N" shortcuts)
//                         → SpaceSwitcher in SystemBridges.swift
// The "SK…" functions are our own small wrappers, written in CGSPrivate.c.
// ======================================================================

#ifndef CGSPRIVATE_H
#define CGSPRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdbool.h>

CF_ASSUME_NONNULL_BEGIN

typedef int32_t CGSConnectionID;
typedef uint64_t CGSSpaceID;

// Private SkyLight calls, re-exported by CoreGraphics. All three are READ-ONLY:
// they report which Spaces exist and which is active. They do not need SIP
// changes and are used by many shipping menu-bar utilities.
extern CGSConnectionID CGSMainConnectionID(void);
extern CGSSpaceID CGSGetActiveSpace(CGSConnectionID cid);
extern CFArrayRef _Nullable CGSCopyManagedDisplaySpaces(CGSConnectionID cid) CF_RETURNS_RETAINED;

// Public-API helper: the UUID string for a CGDirectDisplayID. This matches the
// "Display Identifier" value in the Spaces data, so we can map Spaces to NSScreens.
CFStringRef _Nullable SKCopyDisplayUUIDString(uint32_t displayID) CF_RETURNS_RETAINED;

// Symbolic hotkeys (the system keyboard shortcuts, e.g. "Switch to Desktop N",
// IDs 118…133). Reading and changing them is what System Settings does; the
// change applies immediately. Wrapped so the private calls' types stay in C.
bool SKIsSymbolicHotKeyEnabled(uint32_t hotKey);
bool SKGetSymbolicHotKey(uint32_t hotKey, uint16_t *character, uint16_t *keyCode, uint64_t *modifiers);
bool SKSetSymbolicHotKey(uint32_t hotKey, uint16_t character, uint16_t keyCode, uint64_t modifiers, bool enabled);

CF_ASSUME_NONNULL_END

#endif
