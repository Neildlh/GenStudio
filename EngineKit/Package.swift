// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EngineKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GenStudioEngineKit", targets: ["GenStudioEngineKit"])
    ],
    targets: [
        .target(name: "GenStudioEngineKit"),
        .testTarget(name: "GenStudioEngineKitTests", dependencies: ["GenStudioEngineKit"])
    ]
)
