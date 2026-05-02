// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SendToX4",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SendToX4Core", targets: ["SendToX4Core"]),
        .executable(name: "sendtox4d", targets: ["sendtox4d"])
    ],
    targets: [
        .target(
            name: "SendToX4Core",
            path: "SendToX4/Sources/Core"
        ),
        .executableTarget(
            name: "sendtox4d",
            dependencies: ["SendToX4Core"],
            path: "SendToX4/Sources/Daemon"
        ),
        .executableTarget(
            name: "sendtox4-smoke",
            dependencies: ["SendToX4Core"],
            path: "SendToX4/Sources/SmokeTest"
        )
    ]
)
