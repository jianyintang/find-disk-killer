// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FindDiskKiller",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
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
        .executableTarget(
            name: "FindDiskKillerApp",
            dependencies: ["FindDiskKillerCore"],
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
