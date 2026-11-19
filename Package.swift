// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeployStatus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DeployStatus", targets: ["DeployStatus"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")],
    targets: [
        .target(name: "DeployCore", dependencies: ["Yams"]),
        .executableTarget(name: "DeployStatus", dependencies: ["DeployCore"]),
        .testTarget(name: "DeployCoreTests", dependencies: ["DeployCore"]),
        .testTarget(name: "DeployStatusTests", dependencies: ["DeployStatus", "DeployCore"])
    ]
)
