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
        // All screens. A library so the snapshot tool can render them to images.
        .target(
            name: "EktharDriveUI",
            dependencies: ["EktharDriveCore"],
            path: "Sources/EktharDriveUI"
        ),
        .executableTarget(
            name: "EktharDrive",
            dependencies: ["EktharDriveCore", "EktharDriveUI"],
            path: "Sources/EktharDrive",
            exclude: ["Resources"]
        ),
        // Renders key screens with sample data to PNGs: swift run UISnapshots <out-dir>
        .executableTarget(
            name: "UISnapshots",
            dependencies: ["EktharDriveCore", "EktharDriveUI"],
            path: "Sources/UISnapshots"
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
