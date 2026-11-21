using System.Security.Cryptography;
using System.Text;

namespace Passthrough.Core.Shell.Identity;

/// <summary>
/// Just enough DER to write a self-signed X.509 v3 certificate for a P-256 key: a port of <c>CertificateDER</c> in
/// MacIdentity.swift, byte for byte the same shape, so both hosts present the same kind of certificate. Phones pin it
/// by <see cref="Pin"/>. Not <c>CertificateRequest.CreateSelfSigned</c>, which writes another name encoding and time form.
/// </summary>
public static class CertificateDer
{
    public const string CommonName = "Passthrough PC";

    /// <summary>The to-be-signed part. <paramref name="publicKeyPoint"/> is the uncompressed point (0x04, X, Y: 65 bytes).</summary>
    public static byte[] Tbs(ReadOnlySpan<byte> publicKeyPoint, string commonName, ReadOnlySpan<byte> serial, DateTimeOffset now)
    {
        if (publicKeyPoint.Length != 65 || publicKeyPoint[0] != 0x04) throw new ArgumentException("A P-256 point is 65 bytes, uncompressed.", nameof(publicKeyPoint));
        if (serial.Length != 16) throw new ArgumentException("The serial is 16 bytes.", nameof(serial));
        var positive = serial.ToArray();
        positive[0] &= 0x7F; // positive
        positive[0] |= 0x40; // no leading zero byte needed
        var name = Sequence(Set(Sequence([.. Oid(2, 5, 4, 3), .. Tlv(0x0C, Encoding.UTF8.GetBytes(commonName))])));
        var validity = Sequence([.. Time(now.AddSeconds(-86_400)), .. Time(now.AddSeconds(20L * 365 * 86_400))]);
        var spki = Sequence([.. Sequence([.. Oid(1, 2, 840, 10045, 2, 1), .. Oid(1, 2, 840, 10045, 3, 1, 7)]), .. BitString(publicKeyPoint)]);
        return Sequence([
            .. Tlv(0xA0, Tlv(0x02, [2])), // [0] version v3
            .. Tlv(0x02, positive),
            .. EcdsaWithSha256,
            .. name, .. validity, .. name, .. spki,
        ]);
    }

    /// <summary>The certificate: the to-be-signed part, the algorithm, and the ECDSA signature (DER, r and s).</summary>
    public static byte[] Certificate(ReadOnlySpan<byte> tbs, ReadOnlySpan<byte> signature) => Sequence([.. tbs, .. EcdsaWithSha256, .. BitString(signature)]);

    /// <summary>What phones pin: the lowercase hex SHA-256 of the certificate's DER.</summary>
    public static string Pin(ReadOnlySpan<byte> der) => Convert.ToHexStringLower(SHA256.HashData(der));

    private static readonly byte[] EcdsaWithSha256 = Sequence(Oid(1, 2, 840, 10045, 4, 3, 2));

    internal static byte[] Tlv(byte tag, ReadOnlySpan<byte> content)
    {
        var header = new List<byte> { tag };
        if (content.Length < 0x80) header.Add((byte)content.Length);
        else
        {
            var bytes = new List<byte>();
            for (var length = content.Length; length > 0; length >>= 8) bytes.Insert(0, (byte)(length & 0xFF));
            header.Add((byte)(0x80 | bytes.Count));
            header.AddRange(bytes);
        }
        return [.. header, .. content];
    }

    private static byte[] Sequence(ReadOnlySpan<byte> content) => Tlv(0x30, content);
    private static byte[] Set(ReadOnlySpan<byte> content) => Tlv(0x31, content);
    private static byte[] BitString(ReadOnlySpan<byte> bytes) => Tlv(0x03, [0, .. bytes]);

    internal static byte[] Oid(params uint[] arcs)
    {
        var body = new List<byte> { (byte)(arcs[0] * 40 + arcs[1]) };
        foreach (var arc in arcs.Skip(2))
        {
            var chunk = new List<byte> { (byte)(arc & 0x7F) };
            for (var rest = arc >> 7; rest > 0; rest >>= 7) chunk.Insert(0, (byte)((rest & 0x7F) | 0x80));
            body.AddRange(chunk);
        }
        return Tlv(0x06, [.. body]);
    }

    /// <summary>UTCTime "YYMMDDHHMMSSZ" (valid through 2049).</summary>
    private static byte[] Time(DateTimeOffset date) =>
        Tlv(0x17, Encoding.ASCII.GetBytes(date.UtcDateTime.ToString("yyMMddHHmmss", System.Globalization.CultureInfo.InvariantCulture) + "Z"));
}
