// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MiniMaxUsageMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "MiniMaxUsageMonitor",
            targets: ["MiniMaxUsageMonitor"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MiniMaxUsageMonitor",
            dependencies: [],
            path: "MiniMaxUsageMonitor"
        )
    ]
)
