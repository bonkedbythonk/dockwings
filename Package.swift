// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "DockWings",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "DockWings", path: "Sources/DockWings")
    ],
    swiftLanguageModes: [.v5]
)
