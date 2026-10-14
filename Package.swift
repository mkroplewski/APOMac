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
            path: "Sources/APOMacApp"
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
