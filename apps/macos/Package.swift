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
            ],
            resources: [.copy("Resources/Zurafa-iOS-Default-512@1x.png"),
                        .copy("Resources/light-icons"), .copy("Resources/dark-icons"),
                        .copy("Resources/LobeGithub.png"), .copy("Resources/LobeGithubCopilot.png"),
                        .copy("Resources/SymbolsNerdFontMono-Regular.ttf"), .copy("Resources/SymbolsNerdFont-LICENSE.txt")]),
        .testTarget(name: "ZurafaTests", dependencies: ["Zurafa"]),
    ]
)
