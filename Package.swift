// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "findr",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FindrCore"),
        .executableTarget(
            name: "Findr",
            dependencies: ["FindrCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Quartz"),
                .linkedFramework("PDFKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "FindrCoreTests", dependencies: ["FindrCore"]),
    ],
    swiftLanguageModes: [.v5]
)
