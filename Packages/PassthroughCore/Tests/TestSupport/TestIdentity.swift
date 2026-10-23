#if DEBUG
import Foundation
import CryptoKit
import Security
@testable import PhoneTransport

/// Our certificate for an in-memory key, as an in-memory TLS identity: the
/// system openssl packages key and certificate as PKCS#12 and Security imports
/// it without a keychain (tests can't use the data-protection keychain).
@available(macOS 15, *)
public func makeTestIdentity() throws -> MacIdentity {
    let key = P256.Signing.PrivateKey()
    let tbs = CertificateDER.tbs(publicKeyPoint: key.publicKey.x963Representation, commonName: "Passthrough Mac")
    let der = CertificateDER.certificate(tbs: tbs, signature: try key.signature(for: tbs).derRepresentation)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let pem = "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: .lineLength64Characters) + "\n-----END CERTIFICATE-----\n"
    try pem.write(to: dir.appendingPathComponent("c.pem"), atomically: true, encoding: .utf8)
    try key.pemRepresentation.write(to: dir.appendingPathComponent("k.pem"), atomically: true, encoding: .utf8)
    let openssl = Process()
    openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    openssl.currentDirectoryURL = dir
    openssl.arguments = ["pkcs12", "-export", "-inkey", "k.pem", "-in", "c.pem", "-passout", "pass:test", "-out", "id.p12"]
    try openssl.run(); openssl.waitUntilExit()
    let p12 = try Data(contentsOf: dir.appendingPathComponent("id.p12"))
    var items: CFArray?
    let status = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: "test", kSecImportToMemoryOnly: true] as CFDictionary, &items)
    guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
          let identity = first[kSecImportItemIdentity as String] else { throw MacIdentity.IdentityError.keychain(status, "p12 import") }
    return MacIdentity(identity: identity as! SecIdentity, certificate: der)
}
#endif
