// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetalHUDLogger",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MetalHUDLogger",
            path: "Sources/MetalHUDLogger",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
