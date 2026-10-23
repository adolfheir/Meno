// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenoCLIKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MenoCLIKit", targets: ["MenoCLIKit"])],
    dependencies: [.package(path: "../MenoControlProtocol")],
    targets: [
        .target(name: "MenoCLIKit", dependencies: [.product(name: "MenoControlProtocol", package: "MenoControlProtocol")]),
        .testTarget(name: "MenoCLIKitTests", dependencies: ["MenoCLIKit"]),
    ],
    swiftLanguageModes: [.v5]
)
