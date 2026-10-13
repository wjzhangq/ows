// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OWABridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OWABridge", targets: ["OWABridge"])
    ],
    targets: [
        .target(
            name: "OWABridgeCore",
            path: "Sources/OWABridgeCore",
            resources: [
                .copy("Resources/extractor.js")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit")
            ]
        ),
        .executableTarget(
            name: "OWABridge",
            dependencies: ["OWABridgeCore"],
            path: "Sources/OWABridge"
        ),
        .executableTarget(
            name: "BridgeSelfTest",
            dependencies: ["OWABridgeCore"],
            path: "Sources/BridgeSelfTest"
        )
    ]
)
