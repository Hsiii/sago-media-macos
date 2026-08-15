// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SagoMedia",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SagoMedia", targets: ["SagoMedia"])],
    targets: [.executableTarget(name: "SagoMedia")]
)
