// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIQuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "AIQuotaBar",
            targets: ["AIQuotaBar"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AIQuotaBar",
            dependencies: [],
            path: "AIQuotaBar",
            exclude: ["Resources/Assets.xcassets"]
        )
    ]
)
