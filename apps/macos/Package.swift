// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zurafa",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.99.0")],
    targets: [
        .executableTarget(
            name: "Zurafa",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.copy("Resources/Zurafa-iOS-Default-512@1x.png"), .copy("Resources/Claude.png"),
                        .copy("Resources/SymbolsNerdFontMono-Regular.ttf"), .copy("Resources/SymbolsNerdFont-LICENSE.txt")]),
        .testTarget(name: "ZurafaTests", dependencies: ["Zurafa"]),
    ]
)
