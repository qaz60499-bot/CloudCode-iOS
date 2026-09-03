// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CloudCodeIOS",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "CloudCodeCore", targets: ["CloudCodeCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", revision: "22787ffb59de99e5dc1fbfe80b19c97a904ad48d")
    ],
    targets: [
        .target(
            name: "CloudCodeCore",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Sources/CloudCodeCore"
        ),
        .testTarget(
            name: "CloudCodeCoreTests",
            dependencies: ["CloudCodeCore"],
            path: "Tests/CloudCodeCoreTests"
        )
    ]
)
