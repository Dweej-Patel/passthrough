using System.Security.Cryptography;
using System.Text;

namespace Passthrough.Core.Protocol;

public static class PairingToken
{
    public const int Length = 43;

    /// <summary>Lowercase hex SHA-256, the form the phone stores.</summary>
    public static string Hash(string token) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();

    /// <summary>Whether <paramref name="token"/> has the shape a phone issues (43 URL-safe base64 characters).</summary>
    public static bool IsWellFormed(string token)
    {
        if (token.Length != Length) return false;
        foreach (var c in token)
        {
            var ok = c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_';
            if (!ok) return false;
        }
        return true;
    }
}
