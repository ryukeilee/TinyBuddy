// swift-tools-version: 6.0

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
        .target(
            name: "TinyBuddyCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TinyBuddy",
            dependencies: ["TinyBuddyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TinyBuddyReleaseInstaller",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TinyBuddyReleaseVerifier",
            dependencies: ["TinyBuddyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TinyBuddyCoreTests",
            dependencies: ["TinyBuddyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TinyBuddyAppTests",
            dependencies: ["TinyBuddy", "TinyBuddyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
