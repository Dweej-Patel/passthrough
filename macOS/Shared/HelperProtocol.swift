import Foundation

/// XPC contract between the menu bar app and the privileged tunnel helper.
/// Compiled into both targets.
@objc public protocol PassthroughHelperProtocol {
    func getVersion(reply: @escaping (String) -> Void)
    func startTunnel(configuration: [String: Any], reply: @escaping (Bool, String) -> Void)
    func stopTunnel(reply: @escaping () -> Void)
    func getStatus(reply: @escaping ([String: Any]) -> Void)
    /// Disables/enables ALL system sleep (incl. lid-close) via pmset. Root only.
    func setDisableSleep(_ on: Bool, reply: @escaping (Bool) -> Void)
    func quit()
}

public enum HelperConstants {
    public static let machService = "dev.dpatel.passthrough.helper"
    public static let plistName = "dev.dpatel.passthrough.helper.plist"
    /// Bump together with the helper binary so the app can detect stale daemons.
    public static let version = "1.1.0"
}

/// Keys of the configuration dictionary handed to `startTunnel`.
public enum TunnelConfigKey {
    public static let socksPort = "socksPort"
    public static let username = "username"
    public static let password = "password"
    public static let ipv6 = "ipv6"
    public static let dns = "dns"
    public static let mtu = "mtu"
}

/// Keys of the status dictionary returned by `getStatus`.
public enum TunnelStatusKey {
    public static let running = "running"
    public static let interface = "interface"
    public static let rxBytes = "rxBytes"
    public static let txBytes = "txBytes"
    public static let rxPackets = "rxPackets"
    public static let txPackets = "txPackets"
    public static let since = "since"
}
