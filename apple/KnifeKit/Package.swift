// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KnifeKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KnifeKit", targets: ["KnifeKit"])
    ],
    targets: [
        .target(name: "KnifeKit")
    ]
)
