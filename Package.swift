// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TinyBuddy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TinyBuddy", targets: ["TinyBuddy"])
    ],
    targets: [
        .target(name: "TinyBuddyCore"),
        .executableTarget(
            name: "TinyBuddy",
            dependencies: ["TinyBuddyCore"]
        ),
        .testTarget(
            name: "TinyBuddyCoreTests",
            dependencies: ["TinyBuddyCore"]
        )
    ]
)

