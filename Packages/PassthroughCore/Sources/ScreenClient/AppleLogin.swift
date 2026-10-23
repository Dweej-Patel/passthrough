import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Apple's RFB login (security type 30, "Apple Remote Desktop"): a
/// Diffie-Hellman exchange over the prime and generator the Mac sends, then
/// the account name and password, each in a 64-byte field, AES-128-ECB
/// encrypted under MD5 of the shared secret.
enum AppleLogin {
    enum Failure: Error { case badParameters, cryptoFailed }

    /// The reply to the Mac's parameters: 128 bytes of encrypted login, then
    /// this side's public key (`prime.count` bytes).
    static func response(generator: [UInt8], prime: [UInt8], peerKey: [UInt8],
                         username: String, password: String) throws -> Data {
        let length = prime.count
        guard length >= 16, prime.last.map({ $0 & 1 == 1 }) == true, peerKey.count == length,
              ModArith.compare(peerKey, prime) < 0, ModArith.compare(generator, prime) < 0 else { throw Failure.badParameters }
        // One byte short of the prime, so always below it.
        var secret = [UInt8](repeating: 0, count: length - 1)
        guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else { throw Failure.cryptoFailed }
        let publicKey = ModArith.modPow(base: generator, exponent: secret, modulus: prime)
        let shared = ModArith.modPow(base: peerKey, exponent: secret, modulus: prime)
        let key = Array(Insecure.MD5.hash(data: shared))

        // Random fill, so the fields' unused bytes give nothing away.
        var fields = [UInt8](repeating: 0, count: 128)
        guard SecRandomCopyBytes(kSecRandomDefault, fields.count, &fields) == errSecSuccess else { throw Failure.cryptoFailed }
        for (offset, text) in [(0, username), (64, password)] {
            let bytes = Array(text.utf8.prefix(63))
            fields.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            fields[offset + bytes.count] = 0
        }
        return Data(try aes128ECB(fields, key: key) + publicKey)
    }

    static func aes128ECB(_ input: [UInt8], key: [UInt8], decrypt: Bool = false) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess, moved == input.count else { throw Failure.cryptoFailed }
        return output
    }
}

/// Modular exponentiation for the login's Diffie-Hellman: big-endian byte
/// strings in and out, Montgomery multiplication on 32-bit limbs inside. The
/// modulus must be odd (a DH prime is).
enum ModArith {
    /// Big-endian comparison of unsigned numbers of any lengths.
    static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let a = a.drop { $0 == 0 }, b = b.drop { $0 == 0 }
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return 0
    }

    /// `base`^`exponent` mod `modulus`, as many bytes as `modulus`. `base` must be below it.
    static func modPow(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) -> [UInt8] {
        let n = (modulus.count + 3) / 4
        let m = limbs(modulus, count: n)
        let inverse = negativeInverse(m[0])
        let rSquared = rSquaredMod(m)
        let mont = { (a: [UInt32], b: [UInt32]) in multiply(a, b, m, inverse) }
        let baseMont = mont(limbs(base, count: n), rSquared)
        var one = [UInt32](repeating: 0, count: n)
        one[0] = 1
        var result = mont(one, rSquared)
        for byte in exponent {
            for bit in (0..<8).reversed() {
                result = mont(result, result)
                if byte >> bit & 1 == 1 { result = mont(result, baseMont) }
            }
        }
        return bytes(mont(result, one), length: modulus.count)
    }

    static func limbs(_ bigEndian: [UInt8], count: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: count)
        for (index, byte) in bigEndian.reversed().enumerated() where index / 4 < count {
            out[index / 4] |= UInt32(byte) << (8 * UInt32(index % 4))
        }
        return out
    }

    static func bytes(_ limbs: [UInt32], length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        for index in 0..<length {
            let limb = index / 4
            guard limb < limbs.count else { break }
            out[length - 1 - index] = UInt8(truncatingIfNeeded: limbs[limb] >> (8 * UInt32(index % 4)))
        }
        return out
    }

    /// -m⁻¹ mod 2³² (Newton's iteration; m odd).
    private static func negativeInverse(_ m0: UInt32) -> UInt32 {
        var x: UInt32 = 1
        for _ in 0..<5 { x = x &* (2 &- m0 &* x) }
        return 0 &- x
    }

    /// R² mod m for R = 2^(32n), by doubling 1 that many times.
    private static func rSquaredMod(_ m: [UInt32]) -> [UInt32] {
        var x = [UInt32](repeating: 0, count: m.count)
        x[0] = 1
        for _ in 0..<(64 * m.count) {
            var carry: UInt32 = 0
            for index in x.indices {
                let next = x[index] >> 31
                x[index] = x[index] << 1 | carry
                carry = next
            }
            if carry == 1 || !less(x, m) { subtract(&x, m) }
        }
        return x
    }

    private static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for index in a.indices.reversed() where a[index] != b[index] { return a[index] < b[index] }
        return false
    }

    /// a -= b, wrapping (the caller knows the true result fits).
    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for index in a.indices {
            let difference = UInt64(a[index]) &- UInt64(b[index]) &- borrow
            a[index] = UInt32(truncatingIfNeeded: difference)
            borrow = difference >> 63
        }
    }

    /// a·b·R⁻¹ mod m (CIOS).
    private static func multiply(_ a: [UInt32], _ b: [UInt32], _ m: [UInt32], _ inverse: UInt32) -> [UInt32] {
        let n = m.count
        var t = [UInt64](repeating: 0, count: n + 2)
        for i in 0..<n {
            var carry: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0..<n {
                let sum = t[j] + UInt64(a[j]) * bi + carry
                t[j] = sum & 0xFFFF_FFFF
                carry = sum >> 32
            }
            var sum = t[n] + carry
            t[n] = sum & 0xFFFF_FFFF
            t[n + 1] = sum >> 32
            let factor = UInt64(UInt32(truncatingIfNeeded: t[0]) &* inverse)
            sum = t[0] + factor * UInt64(m[0])
            carry = sum >> 32
            for j in 1..<n {
                sum = t[j] + factor * UInt64(m[j]) + carry
                t[j - 1] = sum & 0xFFFF_FFFF
                carry = sum >> 32
            }
            sum = t[n] + carry
            t[n - 1] = sum & 0xFFFF_FFFF
            t[n] = t[n + 1] + (sum >> 32)
        }
        var result = (0..<n).map { UInt32(truncatingIfNeeded: t[$0]) }
        if t[n] != 0 || !less(result, m) { subtract(&result, m) }
        return result
    }
}
