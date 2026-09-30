// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PassthroughCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PassthroughCore", targets: ["PassthroughCore"]),
        .library(name: "PhoneTransport", targets: ["PhoneTransport"]),
        .library(name: "PassthroughUI", targets: ["PassthroughUI"]),
        .library(name: "VPNConfig", targets: ["VPNConfig"]),
        .executable(name: "passthrough-devserver", targets: ["passthrough-devserver"]),
    ],
    targets: [
        .target(name: "CResolv", linkerSettings: [.linkedLibrary("resolv")]),
        .target(name: "PassthroughCore", dependencies: ["CResolv"]),
        .target(name: "PhoneTransport", dependencies: ["PassthroughCore"]),
        .target(name: "PassthroughUI", dependencies: ["PassthroughCore"]),
        // VPN profile parsing and pinning. Linked by the root helper, so it
        // depends on Foundation and CryptoKit only.
        .target(name: "VPNConfig"),
        .executableTarget(name: "passthrough-devserver", dependencies: ["PassthroughCore"]),
        .testTarget(name: "PassthroughCoreTests", dependencies: ["PassthroughCore", "PhoneTransport"]),
        .testTarget(name: "VPNConfigTests", dependencies: ["VPNConfig"]),
    ]
)
