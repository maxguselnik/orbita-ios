// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OrbitPhysics",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "OrbitPhysics", targets: ["OrbitPhysics"]),
    ],
    targets: [
        .target(name: "OrbitPhysics"),
        .testTarget(name: "OrbitPhysicsTests", dependencies: ["OrbitPhysics"]),
    ]
)
