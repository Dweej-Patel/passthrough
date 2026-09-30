import Foundation

/// A validated OpenVPN profile. The user's file is never handed to the root
/// `openvpn` process as-is: it is tokenised with the same rules OpenVPN uses
/// (leading `--`, tabs, quotes, backslashes), every directive is checked
/// against an allowlist with typed arguments, inline blocks are limited to
/// certificate/key material, and a canonical config is re-emitted. Anything
/// that could run code, touch files, open control sockets, weaken crypto or
/// route around our endpoint pinning is rejected with a clear message.
public struct OpenVPNProfile {
    public private(set) var lines: [String] = []
    public private(set) var endpoints: [(host: String, port: Int)] = []
    public private(set) var tunMTU: Int?
    public private(set) var hasInlineCA = false
    public private(set) var verifyX509Name: String?

    public enum ProfileError: LocalizedError, Equatable {
        case forbidden(String)
        case unsupported(String)
        case badArgument(String, String)
        case badBlock(String)
        case duplicate(String)
        case lineTooLong
        case missing(String)
        public var errorDescription: String? {
            switch self {
            case .forbidden(let d): return "The profile uses '\(d)', which Passthrough does not allow (scripts, files, proxies, control sockets and plugins are refused)."
            case .unsupported(let d): return "The profile uses '\(d)', which Passthrough does not support."
            case .badArgument(let d, let why): return "Bad value for '\(d)': \(why)."
            case .badBlock(let t): return "Unexpected block <\(t)> in the profile."
            case .duplicate(let d): return "The profile has more than one '\(d)'."
            case .lineTooLong: return "The profile has a line longer than \(OpenVPNProfile.maxLineBytes) characters."
            case .missing(let what): return "The profile has no \(what)."
            }
        }
    }

    // Directives that are dangerous under root. Named so the error is specific.
    private static let forbidden: Set<String> = [
        "up", "down", "up-pre", "down-pre", "route-up", "route-pre-down", "ipchange", "client-connect", "client-disconnect",
        "learn-address", "auth-user-pass-verify", "tls-verify", "tls-export-cert", "plugin", "log", "log-append", "writepid",
        "status", "status-version", "dev-node", "config", "askpass", "script-security", "daemon", "inetd", "chroot", "user",
        "group", "client-config-dir", "ccd-exclusive", "iproute", "cd", "tmp-dir", "http-proxy", "http-proxy-option",
        "http-proxy-user-pass", "socks-proxy", "bind", "local", "lport", "windows-driver", "management", "management-client",
        "management-hold", "management-query-passwords", "management-log-cache", "management-signal", "management-forget-disconnect",
        "management-up-down", "management-client-auth", "management-external-key", "management-external-cert", "ping-exit",
        "providers", "engine", "pkcs11-providers", "pkcs11-id", "pkcs11-id-management", "capath", "cryptoapicert", "memstats",
        "echo", "setenv-safe", "genkey", "secret", "mode", "server", "server-bridge",
        "no-replay", "allow-compression", "compress", "comp-noadapt", "proto-force", "http-proxy-retry", "socks-proxy-retry",
    ]
    // Harmless in a client profile but either overridden by our own arguments
    // or irrelevant; dropped silently so common vendor files still import.
    private static let dropped: Set<String> = [
        "verb", "mute", "auth-retry", "ip-win32", "explicit-exit-notify", "keepalive", "ping", "ping-restart", "ping-timer-rem",
        "setenv", "persist-key", "persist-tun", "nobind", "float", "tcp-nodelay", "auth-nocache", "mute-replay-warnings",
        "allow-pull-fqdn", "ns-cert-type", "connect-retry", "connect-retry-max", "connect-timeout", "server-poll-timeout",
        "resolv-retry", "fast-io", "socket-flags", "txqueuelen", "mtu-disc", "replay-window", "hand-window", "tran-window",
        "tls-timeout", "reneg-bytes", "reneg-pkts", "route-delay", "block-ipv6", "ignore-unknown-option", "remote-random-hostname",
        "sndbuf", "rcvbuf", "push-peer-info", "client-nat", "machine-readable-output", "suppress-timestamps",
        // Overridden by the helper's own command line (dev, routing, DNS, pull filters).
        "dev", "dev-type", "route", "route-ipv6", "redirect-gateway", "redirect-private", "route-gateway", "route-metric",
        "route-nopull", "dhcp-option", "block-outside-dns", "ifconfig", "ifconfig-ipv6", "ifconfig-noexec", "route-noexec",
        "pull-filter", "ncp-disable",
    ]
    private static let ciphers: Set<String> = ["AES-256-GCM", "AES-192-GCM", "AES-128-GCM", "CHACHA20-POLY1305", "AES-256-CBC", "AES-192-CBC", "AES-128-CBC"]
    private static let digests: Set<String> = ["SHA1", "SHA256", "SHA384", "SHA512"]
    private static let protos: Set<String> = ["udp", "udp4", "udp6", "tcp", "tcp-client", "tcp4", "tcp4-client", "tcp6", "tcp6-client"]
    private static let inlineTags: Set<String> = ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "dh", "extra-certs", "crl-verify", "pkcs12"]
    /// OpenVPN reads block lines with fgets(line, 256): anything longer is
    /// split, and the tail is read as a fresh line. Every emitted line must fit.
    static let maxLineBytes = 254
    private var blocksSeen: Set<String> = []

    public init(text: String) throws {
        var blockTag: String?
        var blockLines: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let raw = String(rawLine).replacingOccurrences(of: "\r", with: "")
            if let tag = blockTag {
                if raw.trimmingCharacters(in: .whitespaces) == "</\(tag)>" {
                    try emitBlock(tag, blockLines)
                    blockTag = nil; blockLines = []
                } else {
                    blockLines.append(raw)
                }
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), !trimmed.hasPrefix("</") {
                let tag = String(trimmed.dropFirst().dropLast()).lowercased()
                guard Self.inlineTags.contains(tag) else { throw ProfileError.badBlock(tag) }
                blockTag = tag
                continue
            }
            var tokens = Self.tokenize(trimmed)
            guard !tokens.isEmpty else { continue }
            if tokens[0].hasPrefix("--") { tokens[0] = String(tokens[0].dropFirst(2)) }
            try consume(tokens.map { $0 })
        }
        if blockTag != nil { throw ProfileError.badBlock(blockTag!) }
        guard hasInlineCA else { throw ProfileError.missing("inline <ca> certificate") }
        guard !endpoints.isEmpty else { throw ProfileError.missing("'remote' server") }
        guard lines.allSatisfy({ $0.utf8.count <= Self.maxLineBytes }) else { throw ProfileError.lineTooLong }
    }

    /// Tokeniser matching OpenVPN's parse_line: whitespace-separated, single or
    /// double quotes, backslash escapes, '#'/';' starting a comment token.
    public static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character? = nil
        var escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; inToken = true; continue }
            if ch == "\\" && quote != "'" { escaped = true; inToken = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inToken = true; continue }
            if ch == " " || ch == "\t" || ch == "\u{0B}" || ch == "\u{0C}" {
                if inToken { tokens.append(current); current = ""; inToken = false }
                continue
            }
            if (ch == "#" || ch == ";") && !inToken { break }
            current.append(ch); inToken = true
        }
        if inToken { tokens.append(current) }
        return tokens
    }

    private static func isHostname(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 253 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" || $0 == "[" || $0 == "]") }
    }
    private static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:=+/,".contains($0)) }
    }
    private static func int(_ s: String, _ range: ClosedRange<Int>) -> Int? {
        guard let v = Int(s), range.contains(v) else { return nil }
        return v
    }

    private mutating func consume(_ t: [String]) throws {
        let d = t[0].lowercased()
        let args = Array(t.dropFirst())
        if Self.forbidden.contains(d) || d.hasPrefix("management") { throw ProfileError.forbidden(d) }
        if Self.dropped.contains(d) { return }
        switch d {
        case "client", "tls-client", "pull", "remote-random", "auth-user-pass", "comp-lzo":
            if d == "comp-lzo", let a = args.first, a.lowercased() != "no" { throw ProfileError.unsupported("comp-lzo \(a) (compression)") }
            if d == "auth-user-pass", !args.isEmpty { throw ProfileError.forbidden("auth-user-pass <file>") }
            lines.append(d == "comp-lzo" ? "comp-lzo no" : d)
        case "remote":
            guard let host = args.first, Self.isHostname(host) else { throw ProfileError.badArgument(d, "invalid host") }
            var port = 1194
            if args.count >= 2 { guard let p = Self.int(args[1], 1...65535) else { throw ProfileError.badArgument(d, "invalid port") }; port = p }
            var line = "remote \(host) \(port)"
            if args.count >= 3 { guard Self.protos.contains(args[2].lowercased()) else { throw ProfileError.badArgument(d, "unsupported protocol") }; line += " \(args[2].lowercased())" }
            endpoints.append((host, port))
            lines.append(line)
        case "proto":
            guard let p = args.first?.lowercased(), Self.protos.contains(p) else { throw ProfileError.badArgument(d, "unsupported protocol") }
            lines.append("proto \(p)")
        case "tun-mtu", "tun-mtu-extra", "mssfix", "link-mtu", "fragment", "reneg-sec":
            guard let v = Self.int(args.first ?? "", 0...65535) else { throw ProfileError.badArgument(d, "expected a number") }
            if d == "tun-mtu" { tunMTU = v }
            lines.append("\(d) \(v)")
        case "cipher", "data-ciphers-fallback":
            guard let c = args.first?.uppercased(), Self.ciphers.contains(c) else { throw ProfileError.badArgument(d, "only AES-GCM, AES-CBC and ChaCha20-Poly1305 are allowed") }
            lines.append("\(d) \(c)")
        case "data-ciphers", "ncp-ciphers":
            let list = (args.first ?? "").split(separator: ":").map { $0.uppercased() }
            guard !list.isEmpty, list.allSatisfy({ Self.ciphers.contains($0) }) else { throw ProfileError.badArgument(d, "only AES-GCM, AES-CBC and ChaCha20-Poly1305 are allowed") }
            lines.append("data-ciphers \(list.joined(separator: ":"))")
        case "auth":
            guard let a = args.first?.uppercased(), Self.digests.contains(a) else { throw ProfileError.badArgument(d, "unsupported digest") }
            lines.append("auth \(a)")
        case "tls-version-min":
            guard let v = args.first, ["1.2", "1.3"].contains(v) else { throw ProfileError.badArgument(d, "must be 1.2 or 1.3") }
            lines.append("tls-version-min \(v)")
        case "tls-cipher", "tls-ciphersuites":
            guard let v = args.first, Self.isToken(v) else { throw ProfileError.badArgument(d, "invalid list") }
            lines.append("\(d) \(v)")
        case "key-direction":
            guard let v = args.first, ["0", "1"].contains(v) else { throw ProfileError.badArgument(d, "must be 0 or 1") }
            lines.append("key-direction \(v)")
        case "remote-cert-tls":
            guard args.first?.lowercased() == "server" else { throw ProfileError.badArgument(d, "must be 'server'") }
            lines.append("remote-cert-tls server")
        case "verify-x509-name":
            // OpenVPN keeps the last one; a second could override a pinned name.
            guard verifyX509Name == nil else { throw ProfileError.duplicate(d) }
            guard let name = args.first, Self.isToken(name) else { throw ProfileError.badArgument(d, "invalid name") }
            var line = "verify-x509-name \(name)"
            if args.count >= 2 { guard ["subject", "name", "name-prefix"].contains(args[1].lowercased()) else { throw ProfileError.badArgument(d, "invalid type") }; line += " \(args[1].lowercased())" }
            verifyX509Name = name
            lines.append(line)
        case "peer-fingerprint":
            guard let fp = args.first, fp.count <= 200, fp.allSatisfy({ $0.isHexDigit || $0 == ":" }) else { throw ProfileError.badArgument(d, "invalid fingerprint") }
            lines.append("peer-fingerprint \(fp)")
        default:
            throw ProfileError.unsupported(d)
        }
    }

    private mutating func emitBlock(_ tag: String, _ content: [String]) throws {
        // Certificate/key material only: printable ASCII, no '<'. OpenVPN ends a
        // block at any line that *starts* with the close tag after whitespace
        // (so "</ca>x" closes it), and whatever follows would be read as
        // directives. With no '<' in the content, only our own close tag can.
        let ok: (Character) -> Bool = { $0.isASCII && ($0 == "\t" || (" "..."~").contains($0)) && $0 != "<" }
        for l in content where !l.allSatisfy(ok) { throw ProfileError.badBlock(tag) }
        // OpenVPN keeps the last of each; a second <ca> could replace a pinned one.
        guard blocksSeen.insert(tag).inserted else { throw ProfileError.duplicate("<\(tag)>") }
        if tag == "ca" { hasInlineCA = true }
        lines.append("<\(tag)>")
        lines.append(contentsOf: content)
        lines.append("</\(tag)>")
    }

    /// The canonical config text handed to openvpn.
    public var canonicalText: String { lines.joined(separator: "\n") + "\n" }

    /// Text of the inline <ca> block, for identity pinning by callers.
    public var inlineCA: String? {
        guard let start = lines.firstIndex(of: "<ca>"), let end = lines[start...].firstIndex(of: "</ca>") else { return nil }
        return lines[(start + 1)..<end].joined(separator: "\n")
    }
}
