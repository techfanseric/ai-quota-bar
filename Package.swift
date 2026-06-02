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
    dependencies: [
        .package(path: "../../../codexbar")
    ],
    targets: [
        .executableTarget(
            name: "AIQuotaBar",
            dependencies: [
                .product(name: "CodexBarCore", package: "codexbar")
            ],
            path: "AIQuotaBar",
            exclude: ["Resources/Assets.xcassets"]
        )
    ]
)
