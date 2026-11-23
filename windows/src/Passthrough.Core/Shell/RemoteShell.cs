using System.Security.Cryptography;
using System.Text;

namespace Passthrough.Core.Shell;

/// <summary>
/// Shared pieces of the remote shell (protocol/README.md, "Remote shell"); a port of
/// <c>RemoteShell</c> in ShellProtocol.swift.
/// </summary>
public static class RemoteShell
{
    public const int DefaultPort = 7893;
    public const string ServiceType = "_passthrough-sh._tcp";
    public const string ProofLabel = "passthrough-shell-v1";

    /// <summary>Most sessions phones may have open on a host at once.</summary>
    public const int MaxSessions = 8;

    /// <summary>Most sessions started in terminals on the host itself, counted apart from <see cref="MaxSessions"/>.</summary>
    public const int MaxHostSessions = 32;

    /// <summary>Set to the session's id in every session's environment, so a shell started inside one knows it is already shared.</summary>
    public const string SessionVariable = "PASSTHROUGH_SESSION";

    /// <summary>Most views of its screen a host shows at once, to one phone and in all.</summary>
    public const int MaxScreenViewsPerPhone = 2;
    public const int MaxScreenViews = 4;

    /// <summary>Output a session remembers for a phone that attaches later.</summary>
    public const int ScrollbackBytes = 1_048_576;

    /// <summary>Largest piece of raw output (before base64) in one <c>output</c> line.</summary>
    public const int OutputChunk = 16_384;

    /// <summary>Longest line either side accepts.</summary>
    public const int LineLimit = 262_144;

    /// <summary>Longest <c>hello</c> or <c>proof</c> line a host reads before the key is proved.</summary>
    public const int HandshakeLineLimit = 4096;

    /// <summary>Bytes in a shell key and in a challenge nonce.</summary>
    public const int KeyLength = 32;
    public const int NonceLength = 32;

    /// <summary>HMAC-SHA256(shellKey, label ‖ nonce): the phone's answer to the host's challenge.</summary>
    public static byte[] Proof(ReadOnlySpan<byte> shellKey, ReadOnlySpan<byte> nonce)
    {
        var label = Encoding.ASCII.GetBytes(ProofLabel);
        var message = new byte[label.Length + nonce.Length];
        label.CopyTo(message, 0);
        nonce.CopyTo(message.AsSpan(label.Length));
        return HMACSHA256.HashData(shellKey, message);
    }

    /// <summary>Whether <paramref name="mac"/> is the proof for this key and nonce, compared in constant time.</summary>
    public static bool ProofIsValid(ReadOnlySpan<byte> mac, ReadOnlySpan<byte> shellKey, ReadOnlySpan<byte> nonce) =>
        CryptographicOperations.FixedTimeEquals(mac, Proof(shellKey, nonce));
}
