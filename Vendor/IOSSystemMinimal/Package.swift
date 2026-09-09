// swift-tools-version: 5.9
import PackageDescription

// Deliberately re-declares only the four small upstream binary targets required by Cloud Code P0.
// They are split into separate products so XcodeGen can link ios_system itself while merely
// embedding the lazy command frameworks (files/shell/text) without loading them at app startup.
let package = Package(
    name: "IOSSystemMinimal",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "IOSSystemRuntime", targets: ["ios_system"]),
        .library(name: "IOSSystemFiles", targets: ["files"]),
        .library(name: "IOSSystemShell", targets: ["shell"]),
        .library(name: "IOSSystemText", targets: ["text"])
    ],
    targets: [
        .binaryTarget(
            name: "ios_system",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.4/ios_system.xcframework.zip",
            checksum: "6973c1c14a66cdc110a5be7d62991af4546124bd0d9773b5391694b3a93a5be0"
        ),
        .binaryTarget(
            name: "files",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.4/files.xcframework.zip",
            checksum: "02d6522f5e1adc3b472f7aaa53910f049e6c5829e07c7e3005cf2a0d5f9f423a"
        ),
        .binaryTarget(
            name: "shell",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.4/shell.xcframework.zip",
            checksum: "78d71828b89c83741a8f7e857f0d065da72952558fd7deb806f5748c3801fd95"
        ),
        .binaryTarget(
            name: "text",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.4/text.xcframework.zip",
            checksum: "2450f309d0793490136a24f9af02c42fb712b327571cb44312fe330e87a156f2"
        )
    ]
)
