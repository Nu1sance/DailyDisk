// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DailyDisk",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DailyDiskCore", targets: ["DailyDiskCore"]),
        .library(name: "DailyDiskStore", targets: ["DailyDiskStore"]),
        .library(name: "DailyDiskPlatform", targets: ["DailyDiskPlatform"]),
        .executable(name: "DailyDiskApp", targets: ["DailyDiskApp"]),
        .executable(name: "DailyDiskAgent", targets: ["DailyDiskAgent"]),
        .executable(name: "dailydiskctl", targets: ["dailydiskctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "9aa8076dff01b66bcff9335cde02380d59acacc0"
        )
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "DailyDiskCore", resources: [.process("Resources")]),
        .target(
            name: "DailyDiskStore",
            dependencies: ["DailyDiskCore", "CSQLite"],
            resources: [.process("Migrations")]
        ),
        .target(
            name: "DailyDiskPlatform",
            dependencies: ["DailyDiskCore", "DailyDiskStore"],
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "DailyDiskApp",
            dependencies: ["DailyDiskCore", "DailyDiskStore", "DailyDiskPlatform", .product(name: "Sparkle", package: "Sparkle")],
            path: "App/DailyDisk",
            exclude: ["LaunchAgents"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "DailyDiskAgent",
            dependencies: ["DailyDiskPlatform"],
            path: "App/DailyDiskAgent"
        ),
        .executableTarget(
            name: "dailydiskctl",
            dependencies: ["DailyDiskCore", "DailyDiskStore"]
        ),
        .testTarget(
            name: "DailyDiskCoreTests",
            dependencies: [
                "DailyDiskCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DailyDiskStoreTests",
            dependencies: [
                "DailyDiskStore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DailyDiskPlatformTests",
            dependencies: [
                "DailyDiskPlatform",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DailyDiskAppTests",
            dependencies: [
                "DailyDiskApp",
                "DailyDiskCore",
                "DailyDiskStore",
                "DailyDiskPlatform",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DailyDiskCLITests",
            dependencies: [
                "DailyDiskCore",
                "DailyDiskStore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DailyDiskPerformanceTests",
            dependencies: [
                "DailyDiskCore",
                "DailyDiskStore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "DailyDiskIntegrationTests",
            dependencies: [
                "DailyDiskCore",
                "DailyDiskStore",
                "DailyDiskPlatform",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
