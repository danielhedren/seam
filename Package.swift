// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

/// Vendored tree-sitter grammars (Scripts/vendor-grammars.sh): target, directory, grammar
/// subdirectory, and whether it has an external scanner.
let grammars: [(target: String, name: String, directory: String, scanner: Bool)] = [
    ("TreeSitterCSharp", "csharp", ".", true),
    ("TreeSitterTypeScript", "typescript", "typescript", true),
    ("TreeSitterTSX", "tsx", "tsx", true),
    ("TreeSitterJavaScript", "javascript", ".", true),
    ("TreeSitterJSON", "json", ".", false),
    ("TreeSitterYAML", "yaml", ".", true),
    ("TreeSitterMarkdown", "markdown", "tree-sitter-markdown", true),
    ("TreeSitterXML", "xml", "xml", true),
    ("TreeSitterRust", "rust", ".", true),
    ("TreeSitterTOML", "toml", ".", true),
    ("TreeSitterDockerfile", "dockerfile", ".", true),
    ("TreeSitterPHP", "php", "php", true),
]

let grammarTargets: [Target] = grammars.map { grammar in
    let source = grammar.directory == "." ? "grammar/src" : "grammar/\(grammar.directory)/src"
    return .target(
        name: grammar.target, path: "Vendor/Grammars/\(grammar.name)",
        sources: ["\(source)/parser.c"] + (grammar.scanner ? ["\(source)/scanner.c"] : []),
        publicHeadersPath: "include",
        // Generated third-party C: its warnings aren't ours to fix, and the build must stay clean.
        cSettings: [.headerSearchPath(source), .unsafeFlags(["-w"])])
}

/// CryptoKit on Apple platforms, its open-source implementation elsewhere (ADR 0007).
let crypto = Target.Dependency.product(name: "Crypto", package: "swift-crypto")

let package = Package(
    name: "Seam",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SeamCore", targets: ["SeamCore"]),
        .library(name: "DiffView", targets: ["DiffView"]),
        .library(name: "Features", targets: ["Features"]),
        .executable(name: "seam-debug", targets: ["seam-debug"]),
        .executable(name: "seam", targets: ["seam"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.6.1"),
        .package(url: "https://github.com/apple/swift-crypto", exact: "5.0.1"),
    ],
    targets: grammarTargets + [
        .target(name: "GitKit", swiftSettings: strict),
        .target(
            name: "Highlighting",
            dependencies: [
                "SeamCore", "GitKit", crypto,
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            ] + grammars.map { .target(name: $0.target) },
            resources: [.copy("Queries"), .copy("QueryAdditions")], swiftSettings: strict),
        .target(name: "SeamCore", dependencies: ["GitKit", crypto], swiftSettings: strict),
        .target(
            name: "DiffModel", dependencies: ["SeamCore", "GitKit"],
            resources: [.process("Resources")], swiftSettings: strict),
        .target(
            name: "DiffView", dependencies: ["DiffModel", "SeamCore", "GitKit"],
            resources: [.process("Resources")], swiftSettings: strict),
        .target(
            name: "Features",
            dependencies: ["DiffView", "DiffModel", "Highlighting", "SeamCore", "GitKit"],
            resources: [.process("Resources")], swiftSettings: strict),
        .executableTarget(
            name: "seam-debug", dependencies: ["SeamCore", "GitKit"], swiftSettings: strict),
        .executableTarget(
            name: "seam",
            dependencies: [
                "SeamCore", "GitKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ], swiftSettings: strict),
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
            name: "DiffModelTests", dependencies: ["DiffModel", "SeamCore", "GitKit"],
            swiftSettings: strict),
        .testTarget(
            name: "DiffViewTests",
            dependencies: [
                "DiffView", "DiffModel", "SeamCore", "GitKit",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"], swiftSettings: strict),
        .testTarget(
            name: "FeaturesTests",
            dependencies: [
                "Features", "DiffView", "DiffModel", "SeamCore", "GitKit", "TestSupport",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"], swiftSettings: strict),
        .testTarget(
            name: "HighlightingTests", dependencies: ["Highlighting"], swiftSettings: strict),
        .testTarget(
            name: "SeamCoreTests", dependencies: ["SeamCore", "GitKit", "TestSupport"],
            swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)

#if os(Linux)
    /// The targets that build and pass on Linux so far (ADR 0007); `make linux-check` runs them.
    let portable = Set(
        [
            "GitKit", "TestSupport", "GitKitTests", "SeamCore", "SeamCoreTests", "Highlighting",
            "HighlightingTests", "DiffModel", "DiffModelTests", "seam", "seam-debug",
        ] + grammars.map(\.target))
    package.targets.removeAll { !portable.contains($0.name) }
    package.products.removeAll { !portable.contains($0.name) }
#endif
