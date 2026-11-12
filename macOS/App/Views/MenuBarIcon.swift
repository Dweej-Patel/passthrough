import AppKit
import PassthroughUI

/// The menu-bar icon: the phone alone when nothing is on, radio waves while
/// online through it, and a badge beside it for each thing that is on (a lock
/// while the VPN is connected, a cup while Keep awake holds the Mac, a display
/// while a phone is viewing this screen), so it widens only as they appear.
///
/// Colour says what is going on at a glance, the way the system's microphone
/// mark does: green for what is on (online, the VPN, Keep awake), blue for a
/// phone that is plugged in (or linked over Wi-Fi) but not carrying the Mac's
/// traffic (still connecting, or needing pairing), red while the
/// screen is being viewed, and amber for what needs you: a dot on the phone's
/// corner when a shell is waiting on a question, an amber phone with a "!"
/// when something is wrong (the VPN failed and is blocking traffic). With
/// nothing going on it is a plain template image in the bar's own colour.
enum MenuBarIcon {
    struct State: Equatable {
        var online = false
        /// A phone is plugged in (or linked over Wi-Fi) but the Mac isn't online through it; it may still need pairing.
        var phone = false
        var awake = false
        var vpn = false
        /// A phone is viewing this Mac's screen.
        var screen = false
        var needsYou = false
        var problem = false
    }

    private static let gap: CGFloat = 3
    // The app's own palette (PTColor), so a change there reaches the menu bar too.
    private static let amber = PTNSColor.attention
    private static let deepAmber = NSColor(srgbRed: 0.64, green: 0.37, blue: 0, alpha: 1)
    // Each colour as (on a dark bar, on a light bar): the bright one is faint on a light bar.
    private static let green = PTNSColor.tintText
    private static let blue = (NSColor(srgbRed: 0.39, green: 0.71, blue: 1, alpha: 1), NSColor(srgbRed: 0.04, green: 0.42, blue: 0.86, alpha: 1))
    private static let red = PTNSColor.problem
    /// Drawing on a dark menu bar. The bright amber is faint on a light one: deep amber there.
    private static var onDarkBar: Bool { NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    static func image(_ state: State) -> NSImage {
        // Colour can't be a template: then draw at display time in the menu bar's own text colour.
        let colored = state != State()
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
        let parts = [phone(state, ink: .black)] + badges(state, on: .black, viewed: .black)
        let width = parts.map(\.size.width).reduce(0, +) + gap * CGFloat(parts.count - 1)
        return NSSize(width: ceil(width), height: ceil(parts.map(\.size.height).max() ?? 16))
    }

    static func draw(_ state: State, in rect: NSRect, ink: NSColor) {
        let dark = onDarkBar
        let amber = dark ? amber : deepAmber
        func pick(_ color: (NSColor, NSColor)) -> NSColor { dark ? color.0 : color.1 }
        let phoneInk = state.problem ? amber : state.online ? pick(green) : state.phone ? pick(blue) : ink
        let phone = phone(state, ink: phoneInk)
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
        for badge in badges(state, on: pick(green), viewed: pick(red)) {
            x += gap
            badge.draw(at: NSPoint(x: x, y: (rect.height - badge.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            x += badge.size.width
        }
    }

    private static func phone(_ state: State, ink: NSColor) -> NSImage {
        let name = state.online && !state.problem ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3"
        return symbol(name, 15, .regular, ink) ?? NSImage(size: NSSize(width: 12, height: 16))
    }

    /// `on` colours what is switched on; `viewed` the display, while a phone watches it.
    private static func badges(_ state: State, on: NSColor, viewed: NSColor) -> [NSImage] {
        var marks: [(String, NSColor)] = []
        if state.screen { marks.append(("display", viewed)) }
        if state.vpn { marks.append(("lock.fill", on)) }
        if state.awake { marks.append(("cup.and.saucer.fill", on)) }
        return marks.compactMap { symbol($0.0, 11, .semibold, $0.1) }
    }

    private static func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight, _ ink: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [ink])))
    }

    private static func description(_ s: State) -> String {
        var parts = ["Passthrough", s.online ? "online through the phone" : s.phone ? "phone found, Mac not online through it" : "not using the phone"]
        if s.screen { parts.append("a phone is viewing this screen") }
        if s.awake { parts.append("keeping the Mac awake") }
        if s.vpn { parts.append("VPN on") }
        if s.needsYou { parts.append("a shell needs you") }
        if s.problem { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
