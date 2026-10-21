// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "Seam",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SeamCore", targets: ["SeamCore"]),
        .library(name: "DiffView", targets: ["DiffView"]),
        .library(name: "Features", targets: ["Features"]),
        .executable(name: "seam-debug", targets: ["seam-debug"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6")
    ],
    targets: [
        .target(name: "GitKit", swiftSettings: strict),
        .target(name: "SeamCore", dependencies: ["GitKit"], swiftSettings: strict),
        .target(
            name: "DiffView", dependencies: ["SeamCore", "GitKit"],
            resources: [.process("Resources")], swiftSettings: strict),
        .target(
            name: "Features", dependencies: ["DiffView", "SeamCore", "GitKit"],
            resources: [.process("Resources")], swiftSettings: strict),
        .executableTarget(
            name: "seam-debug", dependencies: ["SeamCore", "GitKit"], swiftSettings: strict),
        .target(
            name: "TestSupport", dependencies: ["GitKit"], path: "Tests/TestSupport",
            swiftSettings: strict),
        .testTarget(
            name: "GitKitTests",
            dependencies: ["GitKit", "TestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "DiffViewTests",
            dependencies: [
                "DiffView", "SeamCore", "GitKit",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"], swiftSettings: strict),
        .testTarget(
            name: "FeaturesTests",
            dependencies: ["Features", "DiffView", "SeamCore", "GitKit", "TestSupport"],
            swiftSettings: strict),
        .testTarget(
            name: "SeamCoreTests", dependencies: ["SeamCore", "GitKit", "TestSupport"],
            swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
