// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Entitled",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "EntitledKit", targets: ["EntitledKit"]),
    ],
    targets: [
        .target(
            name: "EntitledKit",
            path: "Sources/EntitledKit",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "EntitledTests",
            dependencies: ["EntitledKit"],
            path: "Tests/EntitledTests"
        ),
    ]
)
