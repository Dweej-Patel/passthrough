import AppKit

/// The menu-bar icon: the phone alone when nothing is on, radio waves while
/// online through it, and a badge beside it for each thing that is on (a lock
/// while the VPN is connected, a cup while Keep awake holds the Mac), so it
/// widens only as they appear. An amber dot on the phone's corner when a shell
/// is waiting on a question, and an amber phone with a "!" when something is
/// wrong (the VPN failed and is blocking traffic).
enum MenuBarIcon {
    struct State: Equatable {
        var online = false
        var awake = false
        var vpn = false
        var needsYou = false
        var problem = false
    }

    private static let gap: CGFloat = 3
    private static let amber = NSColor(srgbRed: 1, green: 0.72, blue: 0.30, alpha: 1)
    private static let deepAmber = NSColor(srgbRed: 0.64, green: 0.37, blue: 0, alpha: 1)
    /// Drawing on a dark menu bar. The bright amber is faint on a light one: deep amber there.
    private static var onDarkBar: Bool { NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    static func image(_ state: State) -> NSImage {
        // Amber can't be a template: then draw at display time in the menu bar's own text colour.
        let colored = state.needsYou || state.problem
        let image = NSImage(size: size(state), flipped: false) { rect in
            draw(state, in: rect, ink: colored ? .labelColor : .black)
            return true
        }
        image.isTemplate = !colored
        image.accessibilityDescription = description(state)
        return image
    }

    /// Just wide enough for the phone and the badges that are on.
    static func size(_ state: State) -> NSSize {
        let parts = [phone(state, ink: .black)] + badges(state, ink: .black)
        let width = parts.map(\.size.width).reduce(0, +) + gap * CGFloat(parts.count - 1)
        return NSSize(width: ceil(width), height: ceil(parts.map(\.size.height).max() ?? 16))
    }

    static func draw(_ state: State, in rect: NSRect, ink: NSColor) {
        let dark = onDarkBar
        let amber = dark ? amber : deepAmber
        let phone = phone(state, ink: state.problem ? amber : ink)
        let phoneOrigin = NSPoint(x: 0, y: (rect.height - phone.size.height) / 2)
        phone.draw(at: phoneOrigin, from: .zero, operation: .sourceOver, fraction: 1)
        // The plain phone glyph's body; the radio-waves one has it in the middle.
        let body = NSRect(x: phoneOrigin.x + (phone.size.width - 10) / 2, y: phoneOrigin.y + 1, width: 10, height: phone.size.height - 2)
        if state.problem, let mark = symbol("exclamationmark", 8, .black, dark ? NSColor(white: 0.12, alpha: 1) : .white) {
            mark.draw(at: NSPoint(x: body.midX - mark.size.width / 2, y: body.midY - mark.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
        }
        if state.needsYou {
            // Cut a ring out of the phone's corner so the dot reads on any bar.
            // Inside the image: it hugs the phone, so nothing past it is drawn.
            let dot = NSRect(x: min(body.maxX - 4, phone.size.width - 6.5), y: rect.maxY - 6.5, width: 6.5, height: 6.5)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            amber.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        var x = phone.size.width
        for badge in badges(state, ink: ink) {
            x += gap
            badge.draw(at: NSPoint(x: x, y: (rect.height - badge.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            x += badge.size.width
        }
    }

    private static func phone(_ state: State, ink: NSColor) -> NSImage {
        let name = state.online && !state.problem ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3"
        return symbol(name, 15, .regular, ink) ?? NSImage(size: NSSize(width: 12, height: 16))
    }

    private static func badges(_ state: State, ink: NSColor) -> [NSImage] {
        var names: [String] = []
        if state.vpn { names.append("lock.fill") }
        if state.awake { names.append("cup.and.saucer.fill") }
        return names.compactMap { symbol($0, 11, .semibold, ink) }
    }

    private static func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight, _ ink: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [ink])))
    }

    private static func description(_ s: State) -> String {
        var parts = ["Passthrough", s.online ? "online through the phone" : "not using the phone"]
        if s.awake { parts.append("keeping the Mac awake") }
        if s.vpn { parts.append("VPN on") }
        if s.needsYou { parts.append("a shell needs you") }
        if s.problem { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
