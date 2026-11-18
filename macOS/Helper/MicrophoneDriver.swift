import Foundation

/// Installs the "Passthrough Microphone" audio driver (macOS/Microphone) where
/// coreaudiod loads drivers from, or removes it. Only root can write there.
///
/// The driver comes from the app bundle this helper runs from, which is in a
/// user-writable place, so it is handled as the VPN engines are (`BundledEngines.stagedEngine`):
/// its files are copied byte for byte into a new root-only directory, the *copy*
/// is verified (strictly, by identifier and Team ID), and the copy is what is
/// moved into place. Nothing can be swapped between the check and the install,
/// and only this app's own signed driver can ever be installed.
enum MicrophoneDriver {
    static let bundleName = "PassthroughMicrophone.driver"
    static let pluginDirectory = "/Library/Audio/Plug-Ins/HAL"
    static var installedPath: String { pluginDirectory + "/" + bundleName }
    /// Next to the plug-in directory, so the move into it is a rename on one volume.
    static let stagingDirectory = "/Library/Audio/Plug-Ins/.PassthroughMicrophone.staging"
    /// Everything the driver's bundle holds. Anything else in it fails the strict signature check.
    static let files = ["Contents/Info.plist", "Contents/MacOS/PassthroughMicrophone", "Contents/_CodeSignature/CodeResources"]
    static let maxFileSize = 8 << 20

    enum Failure: LocalizedError {
        case notBundled
        case notAFile(String)
        case copyFailed(String, Int32)
        case unsafeDirectory(String)
        case unsigned
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .notBundled: return "This build of Passthrough has no microphone driver."
            case .notAFile(let name): return "\(name) in the microphone driver is not a plain file; refusing to install it."
            case .copyFailed(let name, let code): return "Couldn't copy \(name) of the microphone driver (\(String(cString: strerror(code))))."
            case .unsafeDirectory(let path): return "\(path) isn't a directory only root can change; refusing to install a driver there."
            case .unsigned: return "The microphone driver is not signed by this app's team; refusing to install it."
            case .installFailed(let why): return "Couldn't install the microphone driver: \(why)"
            }
        }
    }

    /// The driver inside the app this helper belongs to (`…/Contents/MacOS/PassthroughHelper`).
    static var bundledURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlugIns").appendingPathComponent(bundleName)
    }

    static func install() throws {
        guard let source = bundledURL else { throw Failure.notBundled }
        try requireRootOnly(pluginDirectory)
        try requireRootOnly((stagingDirectory as NSString).deletingLastPathComponent)
        let manager = FileManager.default
        try? manager.removeItem(atPath: stagingDirectory)
        guard mkdir(stagingDirectory, 0o700) == 0 else { throw Failure.copyFailed(stagingDirectory, errno) }
        defer { try? manager.removeItem(atPath: stagingDirectory) }
        let staged = stagingDirectory + "/" + bundleName
        for file in files {
            let directory = ((staged + "/" + file) as NSString).deletingLastPathComponent
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
            try copy(source.appendingPathComponent(file).path, to: staged + "/" + file, executable: file.contains("/MacOS/"), name: file)
        }
        do {
            try BundledEngines.verifySignature(of: URL(fileURLWithPath: staged), identifier: "\(HelperConstants.identifier).microphone")
        } catch {
            throw Failure.unsigned
        }
        // coreaudiod's driver host reads it as its own user: readable by all, writable by root alone.
        for directory in [staged, staged + "/Contents", staged + "/Contents/MacOS", staged + "/Contents/_CodeSignature"] {
            guard chown(directory, 0, 0) == 0, chmod(directory, 0o755) == 0 else { throw Failure.copyFailed(directory, errno) }
        }
        try? manager.removeItem(atPath: installedPath)
        guard rename(staged, installedPath) == 0 else { throw Failure.installFailed(String(cString: strerror(errno))) }
        HelperLog.info("microphone driver installed")
        restartAudio()
    }

    static func remove() throws {
        guard FileManager.default.fileExists(atPath: installedPath) else { return }
        try requireRootOnly(pluginDirectory)
        do {
            try FileManager.default.removeItem(atPath: installedPath)
        } catch {
            throw Failure.installFailed(error.localizedDescription)
        }
        HelperLog.info("microphone driver removed")
        restartAudio()
    }

    /// coreaudiod loads drivers when it starts; launchd starts it again at once.
    /// Sound playing on the Mac stops for a moment.
    private static func restartAudio() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["coreaudiod"]
        process.environment = BundledEngines.environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { HelperLog.warn("couldn't restart coreaudiod (status \(process.terminationStatus)); the driver loads at the next restart") }
        } catch {
            HelperLog.warn("couldn't restart coreaudiod: \(error.localizedDescription)")
        }
    }

    /// A directory owned by root that no one else can write to, and not a link to one.
    private static func requireRootOnly(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0, info.st_mode & 0o022 == 0 else {
            throw Failure.unsafeDirectory(path)
        }
    }

    /// The bytes of the regular file at `source` (never through a final symlink) into a new file.
    private static func copy(_ source: String, to destination: String, executable: Bool, name: String) throws {
        let input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw errno == ENOENT ? Failure.notBundled : Failure.notAFile(name) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxFileSize else { throw Failure.notAFile(name) }
        let mode: mode_t = executable ? 0o755 : 0o644
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard output >= 0 else { throw Failure.copyFailed(name, errno) }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var total = 0
        while true {
            let n = read(input, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw Failure.copyFailed(name, errno) }
            if n == 0 { break }
            total += n
            guard total <= maxFileSize else { throw Failure.notAFile(name) }
            var written = 0
            while written < n {
                let w = buffer[written..<n].withUnsafeBytes { write(output, $0.baseAddress, $0.count) }
                if w < 0, errno == EINTR { continue }
                guard w > 0 else { throw Failure.copyFailed(name, errno) }
                written += w
            }
        }
        guard fchown(output, 0, 0) == 0, fchmod(output, mode) == 0, fsync(output) == 0 else { throw Failure.copyFailed(name, errno) }
    }
}
