// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zurafa",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.99.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.2.1"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
    ],
    targets: [
        .executableTarget(
            name: "Zurafa",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                "GhosttyVt",
            ],
            resources: [.copy("Resources/Zurafa-iOS-Default-1024@1x.png"), .copy("Resources/zurafa-star.png"), .copy("Resources/zurafa-menubar.png"),
                        .copy("Resources/brands"),
                        .copy("Resources/SymbolsNerdFontMono-Regular.ttf"), .copy("Resources/SymbolsNerdFont-LICENSE.txt"),
                        .copy("Resources/themes"), .copy("Resources/Themes-LICENSE.txt"), .copy("Resources/Ghostty-LICENSE.txt")]),
        // libghostty-vt, the terminal-state engine (static library). Official signed release:
        // minisign -V -P RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV -m ghostty-vt-1.0.1.xcframework.zip
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://release.files.ghostty.org/libghostty-vt/1.0.1/ghostty-vt-1.0.1.xcframework.zip",
            checksum: "c0f9631277f726154c8f521954d17cdc41aac4626fc0df8cf925a19ee58e829b"),
        .testTarget(name: "ZurafaTests", dependencies: ["Zurafa"]),
    ]
)
