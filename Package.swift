// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaidUp",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "PaidUpKit", targets: ["PaidUpKit"]),
    ],
    targets: [
        .target(
            name: "PaidUpKit",
            path: "Sources/PaidUpKit",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "PaidUpTests",
            dependencies: ["PaidUpKit"],
            path: "Tests/PaidUpTests"
        ),
    ]
)
