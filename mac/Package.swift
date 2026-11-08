// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "cursoe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "cursoe",
            path: "Sources/cursoe"
        )
    ],
    // Mode bahasa Swift 5: callback C (CGEventTap) dan AppKit lebih sederhana
    // tanpa strict concurrency checking penuh dari Swift 6.
    swiftLanguageModes: [.v5]
)
