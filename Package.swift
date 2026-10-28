// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AfterhoursBlackOut",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AfterhoursBlackOut", targets: ["AfterhoursBlackOut"])],
    targets: [.executableTarget(name: "AfterhoursBlackOut")]
)
