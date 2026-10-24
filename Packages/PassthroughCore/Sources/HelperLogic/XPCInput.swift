import Foundation

/// Typed reads of the values in an XPC configuration dictionary. The root
/// helper takes them from another process, so a value of the wrong type or
/// out of range is refused with a reason instead of trapping a conversion
/// (`UInt16(70000)` crashes the helper) or reaching a command line.
public enum XPCInput {
    public struct Invalid: LocalizedError, Equatable {
        public let key: String
        public init(_ key: String) { self.key = key }
        public var errorDescription: String? { "Invalid value for \(key)" }
    }

    /// An integer in `range`, `fallback` when the key is absent. NSNumber
    /// bridging only yields an `Int` for an exactly representable value.
    public static func integer(_ dict: [String: Any], _ key: String, in range: ClosedRange<Int>, default fallback: Int) throws -> Int {
        guard let raw = dict[key] else { return fallback }
        guard let value = raw as? Int, range.contains(value) else { throw Invalid(key) }
        return value
    }

    /// A TCP/UDP port (1-65535), `fallback` when absent.
    public static func port(_ dict: [String: Any], _ key: String, default fallback: UInt16) throws -> UInt16 {
        let value = try integer(dict, key, in: 1...Int(UInt16.max), default: Int(fallback))
        guard let port = UInt16(exactly: value) else { throw Invalid(key) }
        return port
    }

    public static func bool(_ dict: [String: Any], _ key: String, default fallback: Bool) throws -> Bool {
        guard let raw = dict[key] else { return fallback }
        guard let value = raw as? Bool else { throw Invalid(key) }
        return value
    }

    /// A string of at most `maxLength` characters with no control characters
    /// (a newline would split the line it is written into), `fallback` when
    /// absent. `allowNewlines` is for whole config files.
    public static func string(_ dict: [String: Any], _ key: String, maxLength: Int, allowNewlines: Bool = false,
                              default fallback: String) throws -> String {
        guard let raw = dict[key] else { return fallback }
        guard let value = raw as? String, value.utf8.count <= maxLength,
              !value.unicodeScalars.contains(where: { $0 == "\0" || (!allowNewlines && CharacterSet.controlCharacters.contains($0)) })
        else { throw Invalid(key) }
        return value
    }

    /// A list of at most `maxCount` IPv4/IPv6 address literals, `fallback` when absent.
    public static func ipAddresses(_ dict: [String: Any], _ key: String, maxCount: Int, default fallback: [String]) throws -> [String] {
        guard let raw = dict[key] else { return fallback }
        guard let list = raw as? [String], list.count <= maxCount, list.allSatisfy(isIPAddress) else { throw Invalid(key) }
        return list
    }

    /// Whether `s` is a numeric IPv4 or IPv6 address (no names, no scope, no prefix).
    public static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return s.count <= 45 && (inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1)
    }
}
