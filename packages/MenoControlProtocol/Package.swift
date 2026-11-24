// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MenoControlProtocol", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "MenoControlProtocol", targets: ["MenoControlProtocol"])],
    targets: [.target(name: "MenoControlProtocol"), .testTarget(name: "MenoControlProtocolTests", dependencies: ["MenoControlProtocol"])],
    swiftLanguageModes: [.v5])
