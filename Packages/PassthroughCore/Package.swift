// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PassthroughCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PassthroughCore", targets: ["PassthroughCore"]),
        .library(name: "USBMux", targets: ["USBMux"]),
        .library(name: "PassthroughUI", targets: ["PassthroughUI"]),
        .executable(name: "passthrough-devserver", targets: ["passthrough-devserver"]),
    ],
    targets: [
        .target(name: "PassthroughCore"),
        .target(name: "USBMux", dependencies: ["PassthroughCore"]),
        .target(name: "PassthroughUI", dependencies: ["PassthroughCore"]),
        .executableTarget(name: "passthrough-devserver", dependencies: ["PassthroughCore"]),
        .testTarget(name: "PassthroughCoreTests", dependencies: ["PassthroughCore", "USBMux"]),
    ]
)
