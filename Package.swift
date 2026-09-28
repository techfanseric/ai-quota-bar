// swift-tools-version: 5.9
import PackageDescription
import Foundation

let package = Package(
    name: "AIQuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexUsageAudit", targets: ["CodexUsageAudit"]),
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
        .package(path: FileManager.default.fileExists(atPath: ".dependencies/codexbar/Package.swift")
            ? ".dependencies/codexbar" : "../codexbar")
    ],
    targets: [
        .executableTarget(name: "CodexUsageAudit", dependencies: ["CodexLocalUsageCore"]),
        .target(name: "CodexLocalUsageCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "CodexLocalUsageCoreTests", dependencies: ["CodexLocalUsageCore"]),
        .executableTarget(
            name: "AIQuotaBar",
            dependencies: [
                .product(name: "CodexBarCore", package: "codexbar"),
                "AIQuotaBarSleepShared",
                "CodexLocalUsageCore"
            ],
            path: "AIQuotaBar",
            exclude: ["Resources/Assets.xcassets", "Tests"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // CoreDisplay 只存在于 dyld 共享缓存（磁盘上没有二进制），
                // DDC 显示器信息入口点必须链接时绑定私有框架。
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-weak_framework", "CoreDisplay",
                ]),
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
                .linkedLibrary("sqlite3"),
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-weak_framework", "CoreDisplay",
                ]),
            ]
        )
    ]
)
