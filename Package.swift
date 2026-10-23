// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Meno",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MenoHost", targets: ["MenoHost"]),
        .executable(name: "meno", targets: ["MenoCLI"]),
        .executable(name: "meno-mcp", targets: ["MenoMCP"]),
    ],
    dependencies: [
        .package(path: "packages/MenoPluginKit"),
        .package(path: "packages/MenoCLIKit"),
        .package(path: "plugins/Reminders"),
        .package(path: "packages/MenoControlProtocol"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .executableTarget(
            name: "MenoHost",
            dependencies: [
                .product(name: "MenoPluginKit", package: "MenoPluginKit"),
                .product(name: "RemindersPlugin", package: "Reminders"),
                .product(name: "RemindersCore", package: "Reminders"),
                .product(name: "MenoControlProtocol", package: "MenoControlProtocol"),
            ],
            path: "apps/Meno/Sources"
        ),
        .executableTarget(name: "MenoCLI", dependencies: [
            .product(name: "MenoCLIKit", package: "MenoCLIKit"),
            .product(name: "MenoControlProtocol", package: "MenoControlProtocol"),
        ], path: "apps/MenoCLI/Sources"),
        .executableTarget(name: "MenoMCP", dependencies: [
            .product(name: "MenoControlProtocol", package: "MenoControlProtocol"),
            .product(name: "MCP", package: "swift-sdk"),
        ], path: "apps/MenoMCP/Sources"),
    ],
    swiftLanguageModes: [.v5]
)
