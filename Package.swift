// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StorageBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "StorageBar", path: "Sources/StorageBar"),
        .testTarget(name: "StorageBarTests", dependencies: ["StorageBar"], path: "Tests/StorageBarTests"),
    ]
)
