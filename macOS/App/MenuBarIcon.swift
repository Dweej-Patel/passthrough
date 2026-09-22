import AppKit

/// Composes the menu-bar icon from up to two SF Symbols so it can show four
/// states: passthrough on/off (phone) combined with keep-awake on/off (cup).
enum MenuBarIcon {
    static func image(passthroughOn: Bool, keepAwake: Bool) -> NSImage {
        let phoneName = passthroughOn ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let phone = NSImage(systemSymbolName: phoneName, accessibilityDescription: "Passthrough")?
            .withSymbolConfiguration(config) ?? NSImage()

        guard keepAwake else {
            phone.isTemplate = true
            return phone
        }

        let cupConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Keep awake")?
            .withSymbolConfiguration(cupConfig) ?? NSImage()

        let gap: CGFloat = 3
        let height = max(phone.size.height, cup.size.height)
        let width = phone.size.width + gap + cup.size.width
        let composed = NSImage(size: NSSize(width: width, height: height))
        composed.lockFocus()
        phone.draw(at: NSPoint(x: 0, y: (height - phone.size.height) / 2),
                   from: .zero, operation: .sourceOver, fraction: 1)
        cup.draw(at: NSPoint(x: phone.size.width + gap, y: (height - cup.size.height) / 2),
                 from: .zero, operation: .sourceOver, fraction: 1)
        composed.unlockFocus()
        composed.isTemplate = true
        return composed
    }
}
