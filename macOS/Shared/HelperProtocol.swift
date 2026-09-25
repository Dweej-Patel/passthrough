import Foundation

/// XPC contract between the menu bar app and the privileged tunnel helper.
/// Compiled into both targets.
@objc public protocol PassthroughHelperProtocol {
    func getVersion(reply: @escaping (String) -> Void)
    func startTunnel(configuration: [String: Any], reply: @escaping (Bool, String) -> Void)
    func stopTunnel(reply: @escaping () -> Void)
    /// Whether the phone's network routes IPv6; without it IPv6 is rejected at the tunnel.
    func setTunnelIPv6(_ available: Bool, reply: @escaping () -> Void)
    func getStatus(reply: @escaping ([String: Any]) -> Void)
    /// Disables/enables ALL system sleep (incl. lid-close) via pmset. Root only.
    func setDisableSleep(_ on: Bool, reply: @escaping (Bool) -> Void)
    /// VPN layer: runs a bundled WireGuard/OpenVPN engine on top of whatever
    /// network is current (the passthrough tunnel when it is up).
    func startVPN(configuration: [String: Any], reply: @escaping (Bool, String) -> Void)
    func stopVPN(reply: @escaping () -> Void)
    func quit()
}

public enum HelperConstants {
    public static let machService = "dev.dpatel.passthrough.helper"
    public static let plistName = "dev.dpatel.passthrough.helper.plist"
    /// Bump together with the helper binary so the app can detect stale daemons.
    public static let version = "1.2.13"
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
    /// Absolute path of the running helper binary (to detect a stale registration).
    public static let helperPath = "helperPath"
}

/// Keys of the configuration dictionary handed to `startVPN`.
public enum VPNConfigKey {
    /// "wireguard" or "openvpn".
    public static let engine = "engine"
    /// Display name (e.g. "NordVPN · us9591").
    public static let name = "name"
    /// Full config text (.conf for WireGuard, .ovpn for OpenVPN).
    public static let config = "config"
    public static let username = "username"
    public static let password = "password"
    /// Block all traffic (instead of falling back to the underlay) while the VPN is down.
    public static let killSwitch = "killSwitch"
    /// When the VPN carries no IPv6, reject IPv6 instead of letting it fall through to the underlay.
    public static let blockIPv6 = "blockIPv6"
}

/// Keys of the `vpn` sub-dictionary in `getStatus`.
public enum VPNStatusKey {
    public static let vpn = "vpn"
    /// "off", "starting", "connected", "reconnecting", "blocked", "failed".
    public static let state = "state"
    public static let interface = "interface"
    public static let engine = "engine"
    public static let name = "name"
    public static let rxBytes = "rxBytes"
    public static let txBytes = "txBytes"
    public static let since = "since"
    public static let error = "error"
    public static let underlay = "underlay"
    public static let dns = "dns"
    public static let endpoint = "endpoint"
    /// Seconds since the last WireGuard handshake (WireGuard only).
    public static let handshakeAge = "handshakeAge"
}
