// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MigiAdvanced",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MigiAdvanced", targets: ["MigiAdvanced"])
    ],
    targets: [
        .executableTarget(
            name: "MigiAdvanced",
            path: "Sources/MigiAdvanced",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MigiAdvancedTests",
            dependencies: ["MigiAdvanced"],
            path: "Tests/MigiAdvancedTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
