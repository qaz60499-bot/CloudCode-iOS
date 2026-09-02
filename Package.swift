// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CloudCodeIOS",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "CloudCodeCore", targets: ["CloudCodeCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
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
