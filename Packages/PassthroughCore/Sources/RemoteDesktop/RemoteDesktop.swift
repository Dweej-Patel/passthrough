import Foundation
import PassthroughCore
import ScreenClient
#if canImport(FreeRDP)
import FreeRDP
#endif

/// Whether this build can show a PC's screen.
public enum RemoteDesktop {
    /// The engine is compiled in (Vendor/FreeRDP/FreeRDP.xcframework was there when the package was built).
    public static var isAvailable: Bool {
        #if canImport(FreeRDP)
        return true
        #else
        return false
        #endif
    }

    /// The kill switch: false turns the PC's screen off in the app (between an engine
    /// advisory and its rebuild; CONTRIBUTING's rebuild rule).
    public static let isEnabled = true

    /// A backend for a PC's screen over `stream` (handed over after `rdpReady`), signing in
    /// as `login` to the Remote Desktop whose leaf certificate hashes to `certSHA256`; first
    /// shape `width` x `height` pixels at Windows' `desktopScale` percent. Nil without the
    /// engine or with the kill switch off. Call `start()` on it.
    public static func backend(stream: any ByteStream, initialBytes: Data, certSHA256: String, login: ScreenLogin,
                               width: Int, height: Int, desktopScale: Int = 100, deviceScale: Int = 100, clientName: String,
                               queue: DispatchQueue = .main, onEvent: @escaping (ScreenBackendEvent) -> Void) -> (any ScreenBackend)? {
        #if canImport(FreeRDP)
        guard isEnabled else { return nil }
        return RemoteDesktopBackend(stream: stream, initialBytes: initialBytes, certSHA256: certSHA256, login: login,
                                    layout: .init(width: width, height: height, desktopScale: desktopScale, deviceScale: deviceScale),
                                    clientName: clientName, queue: queue, onEvent: onEvent)
        #else
        return nil
        #endif
    }

    /// The linked engine's FreeRDP and OpenSSL versions, and whether H.264 decodes
    /// through VideoToolbox; nil without the engine.
    public static var engineVersions: (freeRDP: String, openSSL: String, videoToolbox: Bool)? {
        #if canImport(FreeRDP)
        return (String(cString: pt_rdp_freerdp_version()), String(cString: pt_rdp_openssl_version()), pt_rdp_has_videotoolbox() == 1)
        #else
        return nil
        #endif
    }
}
