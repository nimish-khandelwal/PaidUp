// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LeakHarness",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "LeakHarness",
            dependencies: [.product(name: "EntitledKit", package: "Entitled")]
        ),
    ]
)
