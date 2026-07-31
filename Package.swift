// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FindDiskKiller",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FindDiskKillerCore", targets: ["FindDiskKillerCore"]),
        .library(name: "FindDiskKillerNodeRuntime", targets: ["FindDiskKillerNodeRuntime"]),
        .library(name: "FindDiskKillerTraceProtocol", targets: ["FindDiskKillerTraceProtocol"]),
        .library(name: "CFindDiskKillerTrace", targets: ["CFindDiskKillerTrace"]),
        .executable(name: "FindDiskKiller", targets: ["FindDiskKillerApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .target(
            name: "CFindDiskKiller",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("CoreServices")
            ]
        ),
        .target(
            name: "FindDiskKillerCore",
            dependencies: ["CFindDiskKiller"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(name: "FindDiskKillerTraceProtocol"),
        .target(name: "FindDiskKillerNodeRuntime"),
        .target(
            name: "CFindDiskKillerTrace",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "FindDiskKillerApp",
            dependencies: [
                "FindDiskKillerCore",
                "FindDiskKillerNodeRuntime",
                "FindDiskKillerTraceProtocol",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "FindDiskKillerTraceHelper",
            dependencies: [
                "CFindDiskKillerTrace",
                "FindDiskKillerTraceProtocol"
            ]
        ),
        .executableTarget(
            name: "FindDiskKillerClaudeCleanupHelper",
            dependencies: ["FindDiskKillerNodeRuntime"]
        ),
        .testTarget(
            name: "FindDiskKillerCoreTests",
            dependencies: [
                "FindDiskKillerCore",
                "FindDiskKillerTraceProtocol",
                "CFindDiskKillerTrace"
            ]
        ),
        .testTarget(
            name: "FindDiskKillerAppTests",
            dependencies: [
                "FindDiskKillerApp",
                "FindDiskKillerNodeRuntime",
                "FindDiskKillerCore",
                "FindDiskKillerTraceProtocol"
            ]
        ),
        .testTarget(
            name: "TraceHelperTests",
            dependencies: [
                "FindDiskKillerTraceHelper",
                "FindDiskKillerTraceProtocol"
            ],
            path: "Tests/FindDiskKillerTraceHelperTests"
        )
    ]
)
