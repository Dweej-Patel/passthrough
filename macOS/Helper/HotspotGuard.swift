import Foundation

/// Keeps a Mac that joined a phone's hotspot from spending the hotspot's own
/// (often small) data allowance while passthrough is down: reject routes, one
/// step more specific than anything else we route (/4), cover the internet.
/// The hotspot's own subnet (the link to the phone), multicast (Bonjour) and
/// link-local addresses stay reachable. Added fresh so the kernel really
/// rejects; removed when passthrough is up or the app goes away.
enum HotspotGuard {
    static let v4 = (0..<14).map { "\($0 * 16).0.0.0/4" }   // 0/4 … 208/4; 224/4 is multicast
    static let v6 = ["2000::/4", "3000::/4"]                 // global unicast

    private(set) static var isOn = false

    static func set(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if on {
            let t4 = RouteTable.present(v6: false), t6 = RouteTable.present(v6: true)
            for p in v4 where !RouteTable.exists(p, v6: false, in: t4) { _ = try? Shell.run("/sbin/route", ["-q", "-n", "add", "-inet", p, "127.0.0.1", "-reject"], quiet: true) }
            for p in v6 where !RouteTable.exists(p, v6: true, in: t6) { _ = try? Shell.run("/sbin/route", ["-q", "-n", "add", "-inet6", p, "::1", "-reject"], quiet: true) }
            HelperLog.info("hotspot guard on: the phone's hotspot carries only the link to the phone until passthrough is up")
        } else {
            removeAll()
            HelperLog.info("hotspot guard off")
        }
    }

    /// Our reject routes only (also used by the recovery sweep).
    @discardableResult
    static func removeAll() -> [String] {
        var removed: [String] = []
        for p in v4 where RouteTable.isReject(p, v6: false) && RouteTable.deleteIfPresent(p, v6: false) { removed.append(p) }
        for p in v6 where RouteTable.isReject(p, v6: true) && RouteTable.deleteIfPresent(p, v6: true) { removed.append(p) }
        return removed
    }
}
