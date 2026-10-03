// swift-tools-version: 6.2

// ======================================================================
// Package.swift — the build recipe (read by `swift build` and Xcode)
// ======================================================================
// The line above MUST stay the very first line: it tells Swift which
// version of this file's format we use.
//
// Two "targets" (pieces of code that get compiled):
//   • CGSPrivate  — a small C library (Sources/CGSPrivate) that lets Swift
//                   call macOS functions Apple doesn't document.
//   • SpaceKeeper — the app itself (Sources/SpaceKeeper), which uses
//                   CGSPrivate.
// `.defaultIsolation(MainActor.self)` makes all app code run on the main
// (UI) thread unless it says otherwise — simpler and safer for a UI app.
// build.sh runs `swift build`, then wraps the result into SpaceKeeper.app.
// ======================================================================
import PackageDescription

let package = Package(
    name: "SpaceKeeper",
    platforms: [.macOS(.v26)],
    targets: [
        // Thin C bridge to the (read-only) private Spaces calls and a display-UUID helper.
        .target(
            name: "CGSPrivate",
            path: "Sources/CGSPrivate",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "SpaceKeeper",
            dependencies: ["CGSPrivate"],
            path: "Sources/SpaceKeeper",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
