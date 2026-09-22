import SwiftUI

/// The Passthrough visual language: deep graphite surfaces, a teal→violet
/// accent, rounded numerals, and glass cards. Shared by both apps.
public enum PTTheme {
    public static let down = Color(red: 0.25, green: 0.88, blue: 0.82)     // teal: bytes arriving at the Mac
    public static let up = Color(red: 0.71, green: 0.52, blue: 1.0)        // violet: bytes leaving the Mac
    public static let accentStart = down
    public static let accentEnd = up
    public static let warning = Color(red: 1.0, green: 0.72, blue: 0.30)
    public static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)
    public static let success = Color(red: 0.36, green: 0.90, blue: 0.56)

    public static var accent: LinearGradient {
        LinearGradient(colors: [accentStart, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    public static var accentAngular: AngularGradient {
        AngularGradient(colors: [accentStart, accentEnd, accentStart], center: .center)
    }

    public static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    public static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// Background: near-black graphite with two soft accent glows, adapting to light mode.
public struct PTBackground: View {
    @Environment(\.colorScheme) private var scheme
    public var glow: Double
    public init(glow: Double = 1) { self.glow = glow }

    public var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.05, green: 0.06, blue: 0.09) : Color(red: 0.95, green: 0.96, blue: 0.98))
            GeometryReader { geo in
                Circle()
                    .fill(PTTheme.accentStart.opacity((scheme == .dark ? 0.22 : 0.18) * glow))
                    .frame(width: geo.size.width * 0.9)
                    .blur(radius: 90)
                    .offset(x: -geo.size.width * 0.35, y: -geo.size.height * 0.25)
                Circle()
                    .fill(PTTheme.accentEnd.opacity((scheme == .dark ? 0.20 : 0.16) * glow))
                    .frame(width: geo.size.width * 0.8)
                    .blur(radius: 100)
                    .offset(x: geo.size.width * 0.45, y: geo.size.height * 0.45)
            }
            // Rasterise the two blurred glows on the GPU once per change instead
            // of convolving them on the CPU every time the view updates.
            .drawingGroup()
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: glow)
    }
}

/// Glass card container.
public struct PTCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    private let content: Content
    private let padding: CGFloat
    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
    }
    public var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(scheme == .dark ? 0.08 : 0.5), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.08), radius: 18, y: 8)
            }
    }
}

public struct PTSectionTitle: View {
    let text: String
    let icon: String?
    public init(_ text: String, icon: String? = nil) { self.text = text; self.icon = icon }
    public var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.caption.weight(.semibold)) }
            Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(1.1)
        }
        .foregroundStyle(.secondary)
    }
}

/// Small capsule chip, e.g. "5G", "USB", "VPN".
public struct PTPill: View {
    let text: String
    let icon: String?
    let tint: Color
    public init(_ text: String, icon: String? = nil, tint: Color = .secondary) { self.text = text; self.icon = icon; self.tint = tint }
    public var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2.weight(.bold)) }
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Status dot with a soft halo, pulsing when live.
public struct PTStatusDot: View {
    let color: Color
    let live: Bool
    @State private var pulse = false
    public init(color: Color, live: Bool) { self.color = color; self.live = live }
    public var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 16, height: 16)
                .scaleEffect(live && pulse ? 1.5 : 1).opacity(live && pulse ? 0 : 1)
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
    }
}
