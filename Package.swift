// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIQuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "AIQuotaBar",
            targets: ["AIQuotaBar"]
        ),
        .executable(
            name: "AIQuotaBarHook",
            targets: ["AIQuotaBarHook"]
        )
    ],
    dependencies: [
        .package(path: "../codexbar")
    ],
    targets: [
        .executableTarget(
            name: "AIQuotaBar",
            dependencies: [
                .product(name: "CodexBarCore", package: "codexbar"),
                "AIQuotaBarSleepShared"
            ],
            path: "AIQuotaBar",
            exclude: ["Resources/Assets.xcassets", "Tests"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AIQuotaBarHook",
            path: "AIQuotaBarHook"
        ),
        .target(
            name: "AIQuotaBarSleepShared",
            path: "AIQuotaBarSleepShared"
        ),
        .executableTarget(
            name: "AIQuotaBarSleepHelper",
            dependencies: ["AIQuotaBarSleepShared"],
            path: "AIQuotaBarSleepHelper"
        ),
        .testTarget(
            name: "AIQuotaBarTests",
            dependencies: [
                "AIQuotaBar",
                "AIQuotaBarSleepShared",
                .product(name: "CodexBarCore", package: "codexbar")
            ],
            path: "AIQuotaBar/Tests",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
