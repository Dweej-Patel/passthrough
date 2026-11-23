import Foundation

/// The nouns a sentence about one computer uses, by its kind: "your Mac",
/// "the PC". Sentences that differ in more than the noun are in `HostCopy`.
/// A kind of nil (no one computer meant, or a kind this build doesn't know)
/// gives the neutral "computer"; once the kind is known it is never used.
public struct HostWords: Equatable, Sendable {
    public let kind: HostKind?
    /// The host's name as shown (nil: not known).
    public let hostName: String?
    /// This device: "iPhone", "iPad", "phone".
    public let device: String

    public init(kind: HostKind?, name: String?, device: String) {
        self.kind = kind
        self.hostName = name.flatMap { $0.isEmpty ? nil : $0 }
        self.device = device
    }

    /// No one computer meant: lists, pairing, settings.
    public static func generic(device: String) -> HostWords { HostWords(kind: nil, name: nil, device: device) }

    public var noun: String {
        switch kind {
        case .mac: "Mac"
        case .windows: "PC"
        case .other, nil: "computer"
        }
    }

    public var plural: String { noun + "s" }
    public var the: String { "the \(noun)" }
    public var The: String { "The \(noun)" }
    public var your: String { "your \(noun)" }
    public var Your: String { "Your \(noun)" }
    public var this: String { "this \(noun)" }
    public var that: String { "that \(noun)" }
    public var That: String { "That \(noun)" }
    /// The noun to start a sentence with: "Mac", "PC", "Computer".
    public var Noun: String { noun.prefix(1).uppercased() + noun.dropFirst() }
    /// The host's name, else "Your Mac".
    public var name: String { hostName ?? Your }

    /// The page of Passthrough's settings that holds its switches for each phone (Screen, Share): named, since
    /// the PC's settings have four pages.
    public var settingsPage: String {
        switch kind {
        case .mac: "Passthrough's Settings \u{25B8} Remote Shell"
        case .windows: "Passthrough's Settings \u{25B8} Remote access"
        case .other, nil: "Passthrough's settings"
        }
    }

    /// What its setting for letting phones in is called.
    public var feature: String {
        switch kind {
        case .mac: "Remote shell"
        case .windows: "Remote access"
        case .other, nil: "Remote access"
        }
    }

    /// The SF Symbol drawn for it.
    public var symbol: String {
        switch kind {
        case .mac: "laptopcomputer"
        case .windows: "pc"
        case .other, nil: "desktopcomputer"
        }
    }
}
