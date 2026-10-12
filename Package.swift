// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StripMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "StripMac", path: "Sources/StripMac")
    ]
)
