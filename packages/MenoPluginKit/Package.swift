// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenoPluginKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MenoPluginKit", targets: ["MenoPluginKit"])],
    targets: [
        .target(name: "MenoPluginKit"),
        .testTarget(name: "MenoPluginKitTests", dependencies: ["MenoPluginKit"]),
    ],
    swiftLanguageModes: [.v5]
)
