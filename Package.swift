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
// Sources/Libertty/Probes (the UI probe, benches, snapshots) is in debug
// builds only; a release build that needs it (a bench, tests/run.sh release)
// adds -Xswiftc -DLIBERTTY_PROBES, in a scratch path of its own.
// swift-testing's macros, from the toolchain in use (Xcode's or the Command Line Tools').
let toolchain: String = {
    // (Linux has no xcrun: liberttyd's build there doesn't build the tests.)
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return "/usr" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["--find", "swift"]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    p.waitUntilExit()
    let swift = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(fileURLWithPath: swift).deletingLastPathComponent().deletingLastPathComponent().path
}()
let testingPlugin = ["-plugin-path", "\(toolchain)/lib/swift/host/plugins/testing"]
let probes: [SwiftSetting] = [.define("LIBERTTY_PROBES", .when(configuration: .debug))]
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
        // The app, as a library (unit tests import it), and the executable
        // that starts it.
        .target(
            name: "LiberttyApp",
            dependencies: ["CGhosttyVt", "CPty", "LiberttyCore"],
            path: "Sources/LiberttyApp",
            swiftSettings: vtSwift + probes
        ),
        .executableTarget(
            name: "Libertty",
            dependencies: ["LiberttyApp"],
            path: "Sources/Libertty",
            swiftSettings: vtSwift + probes,
            linkerSettings: vtLink + [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
            ]
        ),
        // Unit tests: pure logic, seconds to run (`swift test`). What needs
        // a window or a shell is tests/run.sh's.
        .testTarget(
            name: "LiberttyTests",
            dependencies: ["LiberttyApp", "LiberttyCore"],
            path: "tests/LiberttyTests",
            // (Unsafe flags hide the toolchain's plugin for @Test from the
            // compiler: it's named again, where the toolchain keeps it.)
            swiftSettings: vtSwift + [.unsafeFlags(testingPlugin)],
            linkerSettings: vtLink
        ),
    ]
)
