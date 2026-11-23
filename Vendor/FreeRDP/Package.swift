// swift-tools-version: 5.10
import PackageDescription

// The Remote Desktop engine, built by scripts/build-freerdp.sh: FreeRDP 3,
// OpenSSL 3 and Passthrough's shim as one static library per slice. Its own
// package because a local package can't name a binary outside its root.
// PassthroughCore depends on it only when the xcframework is there.
let package = Package(
    name: "FreeRDP",
    platforms: [.iOS("17.5"), .macOS("14.5")],
    products: [
        .library(name: "FreeRDP", targets: ["FreeRDP"]),
    ],
    targets: [
        .binaryTarget(name: "FreeRDP", path: "FreeRDP.xcframework"),
    ]
)
