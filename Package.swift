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
            dependencies: ["CFindDiskKiller"]
        ),
        .target(name: "FindDiskKillerTraceProtocol"),
        .executableTarget(
            name: "FindDiskKillerApp",
            dependencies: ["FindDiskKillerCore", "FindDiskKillerTraceProtocol"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "FindDiskKillerCoreTests",
            dependencies: ["FindDiskKillerCore"]
        )
    ]
)
