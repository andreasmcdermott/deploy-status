// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeployStatus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DeployStatus", targets: ["DeployStatus"])],
    targets: [
        .target(name: "DeployCore"),
        .executableTarget(name: "DeployStatus", dependencies: ["DeployCore"]),
        .testTarget(name: "DeployCoreTests", dependencies: ["DeployCore"]),
        .testTarget(name: "DeployStatusTests", dependencies: ["DeployStatus", "DeployCore"])
    ]
)
