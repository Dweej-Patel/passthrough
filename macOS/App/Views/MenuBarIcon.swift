import AppKit

/// The menu-bar icon: one phone glyph and a few clear marks. Radio waves while
/// online through the phone, an underline while Keep awake holds the Mac, a
/// shield while the VPN is connected, an amber dot when a shell is waiting on
/// a question, and the glyph turns amber with a "!" when something is wrong
/// (the VPN failed and is blocking traffic).
enum MenuBarIcon {
    struct State: Equatable {
        var online = false
        var awake = false
        var vpn = false
        var needsYou = false
        var problem = false
    }

    static let size = NSSize(width: 33, height: 18)
    private static let amber = NSColor(srgbRed: 1, green: 0.72, blue: 0.30, alpha: 1)

    static func image(_ state: State) -> NSImage {
        // Amber can't be a template: then draw at display time in the menu bar's own text colour.
        let colored = state.needsYou || state.problem
        let image = NSImage(size: size, flipped: false) { rect in
            draw(state, in: rect, ink: colored ? .labelColor : .black)
            return true
        }
        image.isTemplate = !colored
        image.accessibilityDescription = description(state)
        return image
    }

    static func draw(_ state: State, in rect: NSRect, ink: NSColor) {
        let phoneInk = state.problem ? amber : ink
        let name = state.problem ? "iphone.gen3" : state.online ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular).applying(.init(paletteColors: [phoneInk]))
        if let phone = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let origin = NSPoint(x: state.online && !state.problem ? 0 : 4, y: (rect.height - phone.size.height) / 2 + 1)
            phone.draw(at: origin, from: .zero, operation: .sourceOver, fraction: state.online || state.problem ? 1 : 0.85)
            if state.problem {
                let mark = NSImage(systemSymbolName: "exclamationmark", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .black).applying(.init(paletteColors: [NSColor(white: 0.12, alpha: 1)])))
                mark?.draw(at: NSPoint(x: origin.x + phone.size.width / 2 - 2, y: origin.y + phone.size.height / 2 - 4),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        if state.awake {
            ink.setFill()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 0, width: 14, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
        }
        if state.vpn, let shield = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold).applying(.init(paletteColors: [ink]))) {
            shield.draw(at: NSPoint(x: rect.maxX - shield.size.width, y: 1), from: .zero, operation: .sourceOver, fraction: 1)
        }
        if state.needsYou {
            amber.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 6, height: 6)).fill()
        }
    }

    private static func description(_ s: State) -> String {
        var parts = ["Passthrough", s.online ? "online through the phone" : "off"]
        if s.awake { parts.append("keeping the Mac awake") }
        if s.vpn { parts.append("VPN on") }
        if s.needsYou { parts.append("a shell needs you") }
        if s.problem { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
