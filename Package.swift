// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapTap",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TapTapC",
            path: "Sources/TapTapC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "TapTap",
            dependencies: ["TapTapC"],
            path: "Sources/TapTap",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreMotion"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
