import AppKit

/// Composes the menu-bar icon from SF Symbols: the phone shows passthrough
/// on/off, a lock badge appears while the VPN layer is connected, and a cup
/// while keep-awake is on.
enum MenuBarIcon {
    static func image(passthroughOn: Bool, vpnOn: Bool = false, keepAwake: Bool) -> NSImage {
        let phoneName = passthroughOn ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let phone = NSImage(systemSymbolName: phoneName, accessibilityDescription: "Passthrough")?
            .withSymbolConfiguration(config) ?? NSImage()

        var badges: [NSImage] = []
        let badgeConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        if vpnOn, let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "VPN")?.withSymbolConfiguration(badgeConfig) {
            badges.append(lock)
        }
        if keepAwake, let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Keep awake")?.withSymbolConfiguration(badgeConfig) {
            badges.append(cup)
        }
        guard !badges.isEmpty else {
            phone.isTemplate = true
            return phone
        }

        let gap: CGFloat = 3
        let height = ([phone] + badges).map(\.size.height).max() ?? phone.size.height
        let width = phone.size.width + badges.reduce(0) { $0 + gap + $1.size.width }
        let composed = NSImage(size: NSSize(width: width, height: height))
        composed.lockFocus()
        phone.draw(at: NSPoint(x: 0, y: (height - phone.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        var x = phone.size.width
        for badge in badges {
            x += gap
            badge.draw(at: NSPoint(x: x, y: (height - badge.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            x += badge.size.width
        }
        composed.unlockFocus()
        composed.isTemplate = true
        return composed
    }
}
