// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "park",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ParkKit", path: "Sources/ParkKit"),
        .executableTarget(name: "park", dependencies: ["ParkKit"], path: "Sources/park"),
        .executableTarget(name: "ParkApp", dependencies: ["ParkKit"], path: "Sources/ParkApp")
    ]
)
