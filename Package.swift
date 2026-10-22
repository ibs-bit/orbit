// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Orbit", targets: ["Orbit"])],
    targets: [
        .executableTarget(
            name: "Orbit",
            path: "Sources/Orbit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "OrbitTests", dependencies: ["Orbit"], path: "Tests/OrbitTests"),
    ],
    swiftLanguageVersions: [.v5]
)
