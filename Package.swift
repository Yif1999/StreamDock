// swift-tools-version: 6.2
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let libtransportDir = "\(root)/ThirdParty/libtransport"

let package = Package(
    name: "StreamDock",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DockApp", targets: ["DockApp"]),
        .executable(name: "dock-probe", targets: ["DockProbe"]),
        .executable(name: "dock-hook", targets: ["DockHook"]),
    ],
    targets: [
        // Official MiraBox transport library (closed source, prebuilt universal dylib).
        .target(
            name: "CTransport",
            path: "ThirdParty/libtransport",
            exclude: ["LICENSE", "SDK_COMMIT", "libtransport.dylib"],
            sources: ["shim.c"],
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(libtransportDir)", "-ltransport",
                    // App bundle: Contents/Frameworks. `swift run`: the repo copy.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", libtransportDir,
                ]),
            ]
        ),
        .target(
            name: "DockKit",
            dependencies: ["CTransport"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "DockCore", dependencies: ["DockKit"]),
        .testTarget(name: "DockCoreTests", dependencies: ["DockCore"]),
        // Rhythm analysis: audio features → tempo, beats, rhythm state. No UI, no device.
        .target(
            name: "RhythmKit",
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .testTarget(name: "RhythmKitTests", dependencies: ["RhythmKit"]),

        .target(
            name: "ControlModules",
            dependencies: ["DockCore", "RhythmKit"],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("ApplicationServices")]
        ),
        .testTarget(name: "ControlModulesTests", dependencies: ["ControlModules"], exclude: ["OBSFixture.py", "HAFixture.py"]),

        // Scenes are isolated from each other: each depends only on core (and shared modules).
        .target(name: "SceneGeneral", dependencies: ["DockCore", "ControlModules"]),
        .target(name: "SceneVibeCoding", dependencies: ["DockCore", "ControlModules"]),
        .target(name: "SceneSynth", dependencies: ["DockCore"]),

        // The hook command Claude Code and Codex run; Foundation only, starts in milliseconds.
        .executableTarget(name: "DockHook"),

        .executableTarget(
            name: "DockApp",
            dependencies: ["DockKit", "DockCore", "ControlModules", "SceneGeneral", "SceneVibeCoding", "SceneSynth"]
        ),
        .executableTarget(name: "DockProbe", dependencies: ["DockKit", "DockCore", "ControlModules", "RhythmKit"]),
    ]
)
