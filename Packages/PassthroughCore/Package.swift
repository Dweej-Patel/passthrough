// swift-tools-version: 5.10
import Foundation
import PackageDescription

/// The Remote Desktop engine (scripts/build-freerdp.sh) is built by hand and
/// committed separately: until it is there, `RemoteDesktop` builds without it
/// (its backend is `#if canImport(FreeRDP)`) and the app shows no PC screen.
let freeRDPPresent = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: Context.packageDirectory).appendingPathComponent("../../Vendor/FreeRDP/FreeRDP.xcframework").path)

let package = Package(
    name: "PassthroughCore",
    // iroh-ffi's xcframework floors (iOS 17.5 / macOS 14.5) set ours.
    platforms: [.iOS("17.5"), .macOS("14.5")],
    products: [
        .library(name: "PassthroughCore", targets: ["PassthroughCore"]),
        .library(name: "PhoneTransport", targets: ["PhoneTransport"]),
        .library(name: "CUtun", targets: ["CUtun"]),
        .library(name: "PassthroughUI", targets: ["PassthroughUI"]),
        .library(name: "VPNConfig", targets: ["VPNConfig"]),
        .library(name: "HelperLogic", targets: ["HelperLogic"]),
        .library(name: "ShellHost", targets: ["ShellHost"]),
        .library(name: "IrohTransport", targets: ["IrohTransport"]),
        .library(name: "ScreenClient", targets: ["ScreenClient"]),
        .library(name: "ScreenHost", targets: ["ScreenHost"]),
        // Remote Desktop to a PC. App only: never link it into an extension.
        .library(name: "RemoteDesktop", targets: ["RemoteDesktop"]),
        .executable(name: "passthrough-devserver", targets: ["passthrough-devserver"]),
        .executable(name: "passthrough-term", targets: ["passthrough-term"]),
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
        // The utun descriptor of a packet tunnel extension, for the iPad's tun2socks.
        .target(name: "CUtun"),
        .target(name: "PassthroughUI", dependencies: ["PassthroughCore"]),
        // VPN profile parsing and pinning. Linked by the root helper, so it
        // depends on Foundation and CryptoKit only.
        .target(name: "VPNConfig"),
        // The root helper's pure decisions (XPC input checks, process and
        // socket ownership), kept out of the helper so they can be tested.
        // Foundation only, like VPNConfig.
        .target(name: "HelperLogic"),
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
        // Decodes every pixel of every update, so it is optimized in Debug
        // builds too: unoptimized, a full Retina screen takes ~130 ms, optimized ~1 ms.
        .target(name: "ScreenClient", dependencies: ["PassthroughCore", "CZlib"],
                swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // Mac-only: CoreGraphics' private virtual displays (a display shaped like the phone).
        .target(name: "CVirtualDisplay", linkerSettings: [.linkedFramework("CoreGraphics")]),
        // Mac-only: streams the Mac's screen to a phone as H.264 and posts its input.
        .target(name: "ScreenHost", dependencies: ["PassthroughCore", "ShellHost", "CVirtualDisplay"]),
        .executableTarget(name: "passthrough-devserver", dependencies: ["PassthroughCore"]),
        // Mac-only: what a terminal window runs to show one of the app's sessions
        // (the app's own copy is built by the Xcode project from the same source).
        .executableTarget(name: "passthrough-term", dependencies: ["PassthroughCore"]),
        // Helpers shared by the test targets (not a product).
        .target(name: "TestSupport", dependencies: ["PhoneTransport"], path: "Tests/TestSupport"),
        .testTarget(name: "PassthroughCoreTests", dependencies: ["PassthroughCore", "PhoneTransport", "TestSupport"]),
        .testTarget(name: "ShellHostTests", dependencies: ["ShellHost", "IrohTransport", "ScreenClient", "TestSupport"]),
        .testTarget(name: "VPNConfigTests", dependencies: ["VPNConfig"]),
        .testTarget(name: "HelperLogicTests", dependencies: ["HelperLogic"]),
        .testTarget(name: "ScreenClientTests", dependencies: ["ScreenClient", "PassthroughCore"]),
        .testTarget(name: "ScreenHostTests", dependencies: ["ScreenHost", "ScreenClient", "ShellHost", "PassthroughCore"]),
        .testTarget(name: "IrohTransportTests", dependencies: [
            "IrohTransport",
            .product(name: "IrohLib", package: "iroh-ffi"),
        ]),
        .testTarget(name: "RemoteDesktopTests", dependencies: ["RemoteDesktop", "ScreenClient", "PassthroughCore"]),
    ]
)

// A PC's screen through its Remote Desktop: the backend over the engine when the
// engine is there; the pure parts (the certificate pin, the key table) always.
let remoteDesktop = Target.target(name: "RemoteDesktop", dependencies: ["ScreenClient", "PassthroughCore"])
if freeRDPPresent {
    package.dependencies.append(.package(path: "../../Vendor/FreeRDP"))
    remoteDesktop.dependencies.append(.product(name: "FreeRDP", package: "FreeRDP"))
    remoteDesktop.linkerSettings = [
        .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
        .linkedFramework("CoreFoundation"), .linkedFramework("Foundation"), .linkedFramework("Security"),
        .linkedFramework("IOKit", .when(platforms: [.macOS])), .linkedFramework("Carbon", .when(platforms: [.macOS])),
    ]
}
package.targets.append(remoteDesktop)
