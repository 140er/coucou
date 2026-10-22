// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoucouT3Core",
    products: [.library(name: "T3Core", targets: ["T3Core"])],
    targets: [
        .target(name: "T3Core", path: "Sources/T3Core"),
        .testTarget(name: "T3CoreTests", dependencies: ["T3Core"], path: "T3Tests")
    ]
)
