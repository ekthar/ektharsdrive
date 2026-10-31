// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EktharDrive",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EktharDrive", targets: ["EktharDrive"]),
        .library(name: "EktharDriveCore", targets: ["EktharDriveCore"]),
    ],
    targets: [
        .target(
            name: "EktharDriveCore",
            path: "Sources/EktharDriveCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "EktharDrive",
            dependencies: ["EktharDriveCore"],
            path: "Sources/EktharDrive",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "UnitTests",
            dependencies: ["EktharDriveCore"],
            path: "Tests/UnitTests"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["EktharDriveCore"],
            path: "Tests/IntegrationTests"
        ),
    ]
)
