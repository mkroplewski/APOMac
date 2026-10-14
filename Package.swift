// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "APOMac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "APOEngine", targets: ["APOEngine"]),
        .library(name: "APOAudioRuntime", targets: ["APOAudioRuntime"]),
        .executable(name: "APOMacApp", targets: ["APOMacApp"])
    ],
    targets: [
        .target(
            name: "APOEngine",
            path: "Sources/APOEngine"
        ),
        .target(
            name: "APOAudioRuntime",
            dependencies: ["APOEngine"],
            path: "Sources/APOAudioRuntime"
        ),
        .executableTarget(
            name: "APOMacApp",
            dependencies: ["APOEngine", "APOAudioRuntime"],
            path: "Sources/APOMacApp",
            linkerSettings: [
                // Work around SwiftPM's swiftbuild backend recording SDK 15.0,
                // which makes AppKit use the older toolbar appearance. Opt in
                // to the macOS 26 appearance while keeping macOS 15 support.
                .unsafeFlags([
                    "-Xlinker", "-platform_version", "-Xlinker", "macos",
                    "-Xlinker", "15.0", "-Xlinker", "26.0"
                ])
            ]
        ),
        .testTarget(
            name: "APOEngineTests",
            dependencies: ["APOEngine"],
            path: "Tests/APOEngineTests"
        ),
        .testTarget(
            name: "APOMacAppTests",
            dependencies: ["APOEngine", "APOAudioRuntime", "APOMacApp"],
            path: "Tests/APOMacAppTests"
        )
    ]
)
