// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HatorRGB",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HatorRGB", targets: ["HatorRGB"]),
        .executable(name: "hator", targets: ["hator"]),
    ],
    targets: [
        .target(name: "HatorKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "hator", dependencies: ["HatorKit"]),
        .executableTarget(name: "HatorRGB", dependencies: ["HatorKit"]),
    ]
)
