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
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
    ],
    targets: grammarTargets + [
        .target(name: "GitKit", swiftSettings: strict),
        .target(
            name: "Highlighting",
            dependencies: [
                "SeamCore", .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            ] + grammars.map { .target(name: $0.target) },
            resources: [.copy("Queries")], swiftSettings: strict),
        .target(name: "SeamCore", dependencies: ["GitKit"], swiftSettings: strict),
        .target(
            name: "DiffView", dependencies: ["SeamCore", "GitKit"],
            resources: [.process("Resources")], swiftSettings: strict),
        .target(
            name: "Features", dependencies: ["DiffView", "Highlighting", "SeamCore", "GitKit"],
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
            dependencies: [
                "Features", "DiffView", "SeamCore", "GitKit", "TestSupport",
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
