// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DrivePark",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DriveParkKit", path: "Sources/DriveParkKit"),
        .executableTarget(name: "park", dependencies: ["DriveParkKit"], path: "Sources/park"),
        .testTarget(name: "DriveParkKitTests", dependencies: ["DriveParkKit"],
                    path: "Tests/DriveParkKitTests"),
        .executableTarget(name: "DriveParkApp", dependencies: ["DriveParkKit"], path: "Sources/DriveParkApp")
    ]
)
