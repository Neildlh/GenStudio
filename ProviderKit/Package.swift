// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProviderKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GenStudioProviderKit", targets: ["GenStudioProviderKit"])
    ],
    targets: [
        .target(
            name: "GenStudioProviderKit",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "GenStudioProviderKitTests",
            dependencies: ["GenStudioProviderKit"]
        )
    ]
)
