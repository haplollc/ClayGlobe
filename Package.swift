// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClayGlobe",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ClayGlobe", targets: ["ClayGlobe"]),
    ],
    targets: [
        .target(
            name: "ClayGlobe",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "ClayGlobeTests", dependencies: ["ClayGlobe"]),
    ]
)
