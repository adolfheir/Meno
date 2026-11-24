// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reminders",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "RemindersPlugin", targets: ["RemindersPlugin"]), .library(name: "RemindersCore", targets: ["RemindersCore"]),
               .library(name: "RemindersSyncUI", targets: ["RemindersSyncUI"])],
    dependencies: [.package(path: "../../packages/MenoPluginKit"), .package(path: "../../packages/MenoControlProtocol")],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "RemindersCore", dependencies: ["CSQLite", .product(name: "MenoControlProtocol", package: "MenoControlProtocol")]),
        .target(
            name: "RemindersPlugin",
            dependencies: ["RemindersCore", .product(name: "MenoPluginKit", package: "MenoPluginKit"), .product(name: "MenoControlProtocol", package: "MenoControlProtocol")]
        ),
        .target(name: "RemindersSyncUI", dependencies: ["RemindersCore"]),
        .testTarget(name: "RemindersTests", dependencies: ["RemindersCore", "RemindersPlugin", .product(name: "MenoPluginKit", package: "MenoPluginKit"), .product(name: "MenoControlProtocol", package: "MenoControlProtocol")]),
    ],
    swiftLanguageModes: [.v5]
)
