// swift-tools-version:5.9
import PackageDescription

// libghostty-vt, the terminal-state engine (static library), for the Mac and iOS apps. Official signed release:
// minisign -V -P RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV -m ghostty-vt-1.0.1.xcframework.zip
let package = Package(
    name: "GhosttyVt",
    products: [.library(name: "GhosttyVt", targets: ["GhosttyVt"])],
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://release.files.ghostty.org/libghostty-vt/1.0.1/ghostty-vt-1.0.1.xcframework.zip",
            checksum: "c0f9631277f726154c8f521954d17cdc41aac4626fc0df8cf925a19ee58e829b"),
    ]
)
