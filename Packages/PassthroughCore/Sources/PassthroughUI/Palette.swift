import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The redesign's semantic colors: one name per job, a value for each appearance.
/// Mint is the tint and the "on" fill; amber means a person is needed. Text on a
/// mint fill uses `onTint`; mint as text uses `tintText`, darker in light mode so
/// it stays readable on white.
public enum PTColor {
    public static let background = dynamic(light: 0xF2F2F7, dark: 0x0A0B0E)
    public static let surface = dynamic(light: 0xFFFFFF, dark: 0x15171C)
    /// A surface that is switched on.
    public static let surfaceOn = dynamic(light: 0xE2F7EE, dark: 0x10251E)
    public static let hairline = Color.primary.opacity(0.08)

    public static let tint = dynamic(light: 0x3DD9A0, dark: 0x5EE6B5)
    public static let tintText = dynamic(light: 0x0B7A55, dark: 0x5EE6B5)
    public static let onTint = Color(hex: 0x06281C)

    public static let attention = Color(hex: 0xFFB84D)
    public static let attentionText = dynamic(light: 0x8A5300, dark: 0xFFCE85)
    public static let onAttention = Color(hex: 0x2A1A00)
    public static let problem = dynamic(light: 0xC8352A, dark: 0xFF7A6B)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? NSColor(hex: dark) : NSColor(hex: light) })
        #endif
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// A solid content card. Glass is kept for floating controls (tab bar, sheets).
public struct PTSurface<Content: View>: View {
    private let content: Content
    private let padding: CGFloat
    private let fill: Color
    private let stroke: Color
    public init(padding: CGFloat = 16, fill: Color = PTColor.surface, stroke: Color = PTColor.hairline, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
        self.fill = fill
        self.stroke = stroke
    }
    public var body: some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

/// A small mint capsule button. Drawn rather than `.borderedProminent`, which
/// greys out in a window that isn't key (a notch notice never is).
public struct PTPillButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PTColor.onTint)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(PTColor.tint, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The primary action: a mint capsule with dark text (white text on mint is unreadable).
public struct PTProminentButtonStyle: ButtonStyle {
    var fill: Color
    var label: Color
    public init(fill: Color = PTColor.tint, label: Color = PTColor.onTint) { self.fill = fill; self.label = label }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(label)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
