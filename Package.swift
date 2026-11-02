// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-bpm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BPMKit", targets: ["BPMKit"]),
        .executable(name: "bpm-probe", targets: ["bpm-probe"]),
    ],
    targets: [
        .target(name: "BPMKit"),
        .executableTarget(name: "bpm-probe", dependencies: ["BPMKit"]),
        .testTarget(name: "BPMKitTests", dependencies: ["BPMKit"]),
    ]
)
