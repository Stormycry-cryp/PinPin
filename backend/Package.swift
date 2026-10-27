// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PointOut",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PointOutCore", targets: ["PointOut"])],
    targets: [
        .target(name: "PointOut", exclude: ["PointOutApp.swift"]),
        .testTarget(name: "PointOutTests", dependencies: ["PointOut"], resources: [.process("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
