// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TunnelKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TunnelKit", targets: ["TunnelKit"]),
        .executable(name: "portkeep", targets: ["PortkeepCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
    ],
    targets: [
        .target(name: "TunnelKit", resources: [.process("Resources")]),
        // The `portkeep` command line tool and MCP server, copied into Portkeep.app by project.yml.
        .executableTarget(name: "PortkeepCLI", dependencies: ["TunnelKit"]),
        .testTarget(
            name: "TunnelKitTests",
            dependencies: [
                "TunnelKit",
                .product(name: "Clocks", package: "swift-clocks"),
            ]
        ),
    ]
)
