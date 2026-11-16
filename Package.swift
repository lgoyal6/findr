// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Leaf",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "FindrCore"),
        .target(name: "LeafBrowserBridge"),
        .executableTarget(name: "LeafBrowserHost", dependencies: ["LeafBrowserBridge"]),
        .executableTarget(
            name: "Findr",
            dependencies: ["FindrCore", "LeafBrowserBridge", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("Carbon"),
                .linkedFramework("Quartz"),
                .linkedFramework("PDFKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "LeafPDFReader",
            dependencies: ["FindrCore"],
            linkerSettings: [.linkedFramework("PDFKit")]
        ),
        .testTarget(name: "FindrCoreTests", dependencies: ["FindrCore"]),
        .testTarget(name: "FindrTests", dependencies: ["Findr", "FindrCore", "LeafBrowserBridge"]),
    ],
    swiftLanguageModes: [.v5]
)
