// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PassthroughCore",
    // iroh-ffi's xcframework floors (iOS 17.5 / macOS 14.5) set ours.
    platforms: [.iOS("17.5"), .macOS("14.5")],
    products: [
        .library(name: "PassthroughCore", targets: ["PassthroughCore"]),
        .library(name: "PhoneTransport", targets: ["PhoneTransport"]),
        .library(name: "PassthroughUI", targets: ["PassthroughUI"]),
        .library(name: "VPNConfig", targets: ["VPNConfig"]),
        .library(name: "ShellHost", targets: ["ShellHost"]),
        .library(name: "IrohTransport", targets: ["IrohTransport"]),
        .library(name: "ScreenClient", targets: ["ScreenClient"]),
        .executable(name: "passthrough-devserver", targets: ["passthrough-devserver"]),
    ],
    dependencies: [
        // Remote shell over iroh (QUIC, hole punching, relays). Prebuilt
        // checksum-pinned xcframework; macOS slice is arm64 only.
        .package(url: "https://github.com/n0-computer/iroh-ffi", exact: "1.1.0"),
    ],
    targets: [
        .target(name: "CResolv", linkerSettings: [.linkedLibrary("resolv")]),
        .target(name: "PassthroughCore", dependencies: ["CResolv"]),
        // Starts a shell with its pty as controlling terminal (fork + TIOCSCTTY).
        .target(name: "CPTY"),
        .target(name: "PhoneTransport", dependencies: ["PassthroughCore"]),
        .target(name: "PassthroughUI", dependencies: ["PassthroughCore"]),
        // VPN profile parsing and pinning. Linked by the root helper, so it
        // depends on Foundation and CryptoKit only.
        .target(name: "VPNConfig"),
        // Mac-only: hosts login-shell sessions on a PTY for phones to attach to.
        .target(name: "ShellHost", dependencies: ["CPTY", "PassthroughCore", "PhoneTransport", "IrohTransport"]),
        // iroh endpoints and streams as `ByteStream`s. Linked by the Mac and
        // iPhone apps only, never the tunnel extension.
        .target(name: "IrohTransport", dependencies: [
            "PassthroughCore",
            .product(name: "IrohLib", package: "iroh-ffi"),
        ]),
        // zlib's inflate/deflate, whose init macros Swift can't call.
        .target(name: "CZlib", linkerSettings: [.linkedLibrary("z")]),
        // The phone's viewer for macOS Screen Sharing (RFB) over the remote shell.
        .target(name: "ScreenClient", dependencies: ["PassthroughCore", "CZlib"]),
        .executableTarget(name: "passthrough-devserver", dependencies: ["PassthroughCore"]),
        // Helpers shared by the test targets (not a product).
        .target(name: "TestSupport", dependencies: ["PhoneTransport"], path: "Tests/TestSupport"),
        .testTarget(name: "PassthroughCoreTests", dependencies: ["PassthroughCore", "PhoneTransport", "TestSupport"]),
        .testTarget(name: "ShellHostTests", dependencies: ["ShellHost", "IrohTransport", "ScreenClient", "TestSupport"]),
        .testTarget(name: "VPNConfigTests", dependencies: ["VPNConfig"]),
        .testTarget(name: "ScreenClientTests", dependencies: ["ScreenClient", "PassthroughCore"]),
        .testTarget(name: "IrohTransportTests", dependencies: [
            "IrohTransport",
            .product(name: "IrohLib", package: "iroh-ffi"),
        ]),
    ]
)
