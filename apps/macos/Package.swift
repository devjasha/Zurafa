// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zurafa",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.99.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Zurafa",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources/Zurafa-iOS-Default-512@1x.png"), .copy("Resources/Claude.png"),
                        .copy("Resources/LobeClaude.png"), .copy("Resources/LobeCodex.png"),
                        .copy("Resources/LobeGemini.png"), .copy("Resources/LobeOpenAI.png"),
                        .copy("Resources/LobeGithub.png"), .copy("Resources/LobeGithubCopilot.png"),
                        .copy("Resources/SymbolsNerdFontMono-Regular.ttf"), .copy("Resources/SymbolsNerdFont-LICENSE.txt")]),
        .testTarget(name: "ZurafaTests", dependencies: ["Zurafa"]),
    ]
)
