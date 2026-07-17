// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Repeatizer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RepeatizerCore", targets: ["RepeatizerCore"]),
        .executable(name: "RepeatizerPreview", targets: ["RepeatizerPreview"])
    ],
    targets: [
        .target(name: "RepeatizerCore"),
        .executableTarget(name: "RepeatizerPreview", dependencies: ["RepeatizerCore"]),
        .testTarget(name: "RepeatizerCoreTests", dependencies: ["RepeatizerCore"])
    ]
)
