// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PassthroughCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PassthroughCore", targets: ["PassthroughCore"]),
        .library(name: "PhoneTransport", targets: ["PhoneTransport"]),
        .library(name: "PassthroughUI", targets: ["PassthroughUI"]),
        .executable(name: "passthrough-devserver", targets: ["passthrough-devserver"]),
    ],
    targets: [
        .target(name: "CResolv", linkerSettings: [.linkedLibrary("resolv")]),
        .target(name: "PassthroughCore", dependencies: ["CResolv"]),
        .target(name: "PhoneTransport", dependencies: ["PassthroughCore"]),
        .target(name: "PassthroughUI", dependencies: ["PassthroughCore"]),
        .executableTarget(name: "passthrough-devserver", dependencies: ["PassthroughCore"]),
        .testTarget(name: "PassthroughCoreTests", dependencies: ["PassthroughCore", "PhoneTransport"]),
    ]
)
