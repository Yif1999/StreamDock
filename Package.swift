// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let libtransportDir = "\(root)/ThirdParty/libtransport"

let package = Package(
    name: "StreamDock",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DockApp", targets: ["DockApp"]),
        .executable(name: "dock-probe", targets: ["DockProbe"]),
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
        .testTarget(name: "ControlModulesTests", dependencies: ["ControlModules"]),

        // Scenes are isolated from each other: each depends only on core (and shared modules).
        .target(name: "SceneGeneral", dependencies: ["DockCore", "ControlModules"]),
        .target(name: "SceneVibeCoding", dependencies: ["DockCore"]),
        .target(name: "SceneSynth", dependencies: ["DockCore"]),

        .executableTarget(
            name: "DockApp",
            dependencies: ["DockKit", "DockCore", "SceneGeneral", "SceneVibeCoding", "SceneSynth"]
        ),
        .executableTarget(name: "DockProbe", dependencies: ["DockKit", "DockCore", "ControlModules", "RhythmKit"]),
    ]
)
