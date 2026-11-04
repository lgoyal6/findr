// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "findr",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FindrCore"),
        .testTarget(name: "FindrCoreTests", dependencies: ["FindrCore"]),
    ],
    swiftLanguageModes: [.v5]
)
