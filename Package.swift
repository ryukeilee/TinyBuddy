// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TinyBuddy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TinyBuddy", targets: ["TinyBuddy"]),
        .executable(
            name: "TinyBuddyReleaseInstaller",
            targets: ["TinyBuddyReleaseInstaller"]
        ),
        .executable(
            name: "TinyBuddyReleaseVerifier",
            targets: ["TinyBuddyReleaseVerifier"]
        )
    ],
    targets: [
        .target(name: "TinyBuddyCore"),
        .executableTarget(
            name: "TinyBuddy",
            dependencies: ["TinyBuddyCore"]
        ),
        .executableTarget(name: "TinyBuddyReleaseInstaller"),
        .executableTarget(
            name: "TinyBuddyReleaseVerifier",
            dependencies: ["TinyBuddyCore"]
        ),
        .testTarget(
            name: "TinyBuddyCoreTests",
            dependencies: ["TinyBuddyCore"]
        ),
        .testTarget(
            name: "TinyBuddyAppTests",
            dependencies: ["TinyBuddy", "TinyBuddyCore"]
        )
    ]
)
