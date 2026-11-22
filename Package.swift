// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "goshawk-ime",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GoshawkCore",
            targets: ["GoshawkCore"]
        ),
        .executable(
            name: "GoshawkCLI",
            targets: ["GoshawkCLI"]
        ),
        .executable(
            name: "GoshawkVerifier",
            targets: ["GoshawkVerifier"]
        ),
        .executable(
            name: "GoshawkApp",
            targets: ["GoshawkApp"]
        )
    ],
    targets: [
        .target(
            name: "GoshawkCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "GoshawkCLI",
            dependencies: ["GoshawkCore"]
        ),
        .executableTarget(
            name: "GoshawkVerifier",
            dependencies: ["GoshawkCore"]
        ),
        .executableTarget(
            name: "GoshawkApp",
            dependencies: ["GoshawkCore"]
        ),
        .testTarget(
            name: "GoshawkAppTests",
            dependencies: ["GoshawkApp", "GoshawkCore"]
        ),
        .testTarget(
            name: "GoshawkCoreTests",
            dependencies: ["GoshawkCore", "GoshawkVerifier"]
        )
    ]
)
