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
        .library(name: "FindDiskKillerTraceProtocol", targets: ["FindDiskKillerTraceProtocol"]),
        .library(name: "CFindDiskKillerTrace", targets: ["CFindDiskKillerTrace"]),
        .executable(name: "FindDiskKiller", targets: ["FindDiskKillerApp"])
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
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication")
            ]
        ),
        .target(name: "FindDiskKillerTraceProtocol"),
        .target(
            name: "CFindDiskKillerTrace",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "FindDiskKillerApp",
            dependencies: ["FindDiskKillerCore", "FindDiskKillerTraceProtocol"],
            resources: [
                .process("Resources")
            ]
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
                "FindDiskKillerCore",
                "FindDiskKillerTraceProtocol"
            ]
        )
    ]
)
