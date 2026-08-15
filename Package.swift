// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SagoDrop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SagoDrop", targets: ["SagoDrop"])],
    targets: [
        .executableTarget(name: "SagoDrop"),
        .testTarget(name: "SagoDropTests", dependencies: ["SagoDrop"]),
    ]
)
