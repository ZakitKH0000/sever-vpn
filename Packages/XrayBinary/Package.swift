// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XrayBinary",
    platforms: [.iOS(.v17)],
    products: [.library(name: "LibXray", targets: ["LibXray"])],
    targets: [.binaryTarget(name: "LibXray", path: "LibXray.xcframework")]
)
