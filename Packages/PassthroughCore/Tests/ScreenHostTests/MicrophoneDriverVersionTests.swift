import CryptoKit
import XCTest

/// The Mac app decides whether the installed "Passthrough Microphone" driver needs replacing by the driver's
/// version (CFBundleVersion), not by its bytes: the same source builds to different bytes in every build of the
/// app. That only works if the version changes whenever the source does, which this holds together.
final class MicrophoneDriverVersionTests: XCTestCase {
    /// The driver's version, and the SHA-256 of the source it was given for. Changing
    /// macOS/Microphone/PassthroughMicrophone.c fails this test until both are updated: raise `version` here and
    /// PASSTHROUGH_MICROPHONE_VERSION in project.yml together, then record the new hash.
    private static let version = "1"
    private static let sourceSHA256 = "e226b8b2768ff9d113c8b9ec1b0d297065300832556c5a35fe5161ee82c669d9"

    private var repository: URL {
        // Tests/ScreenHostTests/<this file> → the repository's root.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheDriversVersionChangesWithItsSource() throws {
        let source = try Data(contentsOf: repository.appendingPathComponent("macOS/Microphone/PassthroughMicrophone.c"))
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.sourceSHA256,
                       "The microphone driver's source changed: raise its version (here and PASSTHROUGH_MICROPHONE_VERSION in project.yml), then record this hash.")
    }

    func testTheProjectBuildsTheDriverWithThatVersion() throws {
        let project = try String(contentsOf: repository.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("PASSTHROUGH_MICROPHONE_VERSION: \"\(Self.version)\""),
                      "project.yml must set PASSTHROUGH_MICROPHONE_VERSION to \(Self.version)")
        let plist = try String(contentsOf: repository.appendingPathComponent("macOS/Microphone/Info.plist"), encoding: .utf8)
        XCTAssertTrue(plist.contains("<string>$(PASSTHROUGH_MICROPHONE_VERSION)</string>"),
                      "The driver's CFBundleVersion must be its own version, not the app's build number")
    }
}
