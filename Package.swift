// swift-tools-version: 5.9
import Foundation
import PackageDescription

// libghostty-vt is built by scripts/build-libghostty-vt.sh into vendor/ghostty/zig-out.
// We link the static archive by path so the dylib next to it is never picked up.
// Headers come through Sources/CGhosttyVt/include/ghostty (a symlink to only the
// vt headers): vendor/ghostty/include also holds a module map for the full
// GhosttyKit app library, which would otherwise claim these headers.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ghostty = "\(root)/vendor/ghostty"
let vtHeaders = "\(root)/Sources/CGhosttyVt/include"
// scripts/build-linux-liberttyd.sh points this at a Linux build of the library.
let vtLibrary = ProcessInfo.processInfo.environment["LIBERTTY_VT_LIBRARY"] ?? "\(ghostty)/zig-out/lib/libghostty-vt.a"
let vtSwift: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(vtHeaders)"])]
let vtLink: [LinkerSetting] = [
    .unsafeFlags([vtLibrary]),
    .linkedLibrary("c++"),
]

let package = Package(
    name: "Libertty",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CGhosttyVt", path: "Sources/CGhosttyVt"),
        .target(name: "CPty", path: "Sources/CPty"),
        // What the app and liberttyd share: the pty, the daemon protocol and server.
        .target(
            name: "LiberttyCore",
            dependencies: ["CGhosttyVt", "CPty"],
            path: "Sources/LiberttyCore",
            swiftSettings: vtSwift
        ),
        // liberttyd: keeps sessions (pty + terminal state) alive while the app is closed.
        // Its Info.plist is embedded: macOS reads a program's privacy texts from the
        // process responsible for it, and liberttyd answers for its programs.
        .executableTarget(
            name: "liberttyd",
            dependencies: ["LiberttyCore"],
            path: "Sources/liberttyd",
            exclude: ["Info.plist"],
            swiftSettings: vtSwift,
            linkerSettings: vtLink + [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(root)/Sources/liberttyd/Info.plist"], .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "Libertty",
            dependencies: ["CGhosttyVt", "CPty", "LiberttyCore"],
            path: "Sources/Libertty",
            swiftSettings: vtSwift,
            linkerSettings: vtLink + [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
            ]
        ),
    ]
)
