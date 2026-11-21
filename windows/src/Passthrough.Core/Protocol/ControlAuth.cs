using System.Security.Cryptography;
using System.Text;

namespace Passthrough.Core.Protocol;

/// <summary>
/// How the PC and a phone prove a pairing to each other (protocol version 2). Both sides prove they
/// know K = SHA-256(token) by an HMAC over a fresh nonce from each side; the phone proves first.
/// </summary>
public static class ControlAuth
{
    public const string PhoneLabel = "passthrough-control-v2 phone";
    public const string MacLabel = "passthrough-control-v2 mac";
    public const string SocksLabel = "passthrough-socks-v2";
    public const int NonceLength = 32;

    public static byte[] Key(string token) => SHA256.HashData(Encoding.UTF8.GetBytes(token));

    public static byte[] Nonce() => RandomNumberGenerator.GetBytes(NonceLength);

    /// <summary>A nonce from the wire: base64 of exactly <see cref="NonceLength"/> bytes, else null.</summary>
    public static byte[]? DecodeNonce(string? text)
    {
        var data = TryBase64(text);
        return data is { Length: NonceLength } ? data : null;
    }

    /// <summary>The phone's proof: HMAC(K, phoneLabel || clientID || macNonce || phoneNonce).</summary>
    public static byte[] PhoneProof(byte[] key, string clientId, byte[] macNonce, byte[] phoneNonce) =>
        HMACSHA256.HashData(key, Message(PhoneLabel, clientId, macNonce, phoneNonce));

    /// <summary>The PC's proof: HMAC(K, macLabel || clientID || phoneNonce || macNonce).</summary>
    public static byte[] MacProof(byte[] key, string clientId, byte[] macNonce, byte[] phoneNonce) =>
        HMACSHA256.HashData(key, Message(MacLabel, clientId, phoneNonce, macNonce));

    /// <summary>Constant-time check of a phone's proof; false for anything not valid base64.</summary>
    public static bool IsValidPhoneProof(string? proofBase64, byte[] key, string clientId, byte[] macNonce, byte[] phoneNonce)
    {
        var code = TryBase64(proofBase64);
        return code is not null
            && CryptographicOperations.FixedTimeEquals(code, PhoneProof(key, clientId, macNonce, phoneNonce));
    }

    /// <summary>The SOCKS5 password: HMAC(K, socksLabel) as unpadded URL-safe base64.</summary>
    public static string SocksPassword(byte[] key) =>
        Convert.ToBase64String(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(SocksLabel)))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static byte[] Message(string label, string clientId, byte[] first, byte[] second)
    {
        var l = Encoding.UTF8.GetBytes(label);
        var c = Encoding.UTF8.GetBytes(clientId);
        var m = new byte[l.Length + c.Length + first.Length + second.Length];
        l.CopyTo(m, 0);
        c.CopyTo(m, l.Length);
        first.CopyTo(m, l.Length + c.Length);
        second.CopyTo(m, l.Length + c.Length + first.Length);
        return m;
    }

    private static byte[]? TryBase64(string? text)
    {
        if (text is null) return null;
        try { return Convert.FromBase64String(text); }
        catch (FormatException) { return null; }
    }
}
