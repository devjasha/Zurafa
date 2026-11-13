// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zurafa",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.2.1"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
        .package(path: "../GhosttyVt"),
    ],
    targets: [
        .executableTarget(
            name: "Zurafa",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "GhosttyVt", package: "GhosttyVt"),
            ],
            resources: [.copy("Resources/Zurafa-iOS-Default-1024@1x.png"), .copy("Resources/zurafa-star.png"), .copy("Resources/zurafa-menubar.png"),
                        .copy("Resources/brands"),
                        .copy("Resources/SymbolsNerdFontMono-Regular.ttf"), .copy("Resources/SymbolsNerdFont-LICENSE.txt"),
                        .copy("Resources/themes"), .copy("Resources/Themes-LICENSE.txt"), .copy("Resources/Ghostty-LICENSE.txt")]),
        .testTarget(name: "ZurafaTests", dependencies: ["Zurafa"]),
    ]
)
