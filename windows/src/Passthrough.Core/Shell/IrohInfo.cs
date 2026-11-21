using System.Text;

namespace Passthrough.Core.Shell;

/// <summary>What a phone accepts as a host's iroh details (grant and <c>macInfo</c>); port of ShellProtocol.swift.</summary>
public static class IrohInfo
{
    public const int MaxRelayLength = 256;
    public const int MaxTokenLength = 512;
    public const int MaxAddresses = 16;

    /// <summary>An iroh EndpointId: 64 lowercase hex characters.</summary>
    public static bool IsValidId(string? id) =>
        id is { Length: 64 } && id.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    /// <summary>An https URL with a host, at most <see cref="MaxRelayLength"/> UTF-8 bytes.</summary>
    public static bool IsValidRelay(string? relay)
    {
        if (relay is null || Encoding.UTF8.GetByteCount(relay) > MaxRelayLength) return false;
        return Uri.TryCreate(relay, UriKind.Absolute, out var url)
            && url.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)
            && url.Host.Length > 0;
    }

    /// <summary>At most <see cref="MaxTokenLength"/> UTF-8 bytes.</summary>
    public static bool IsValidToken(string? token) => token is not null && Encoding.UTF8.GetByteCount(token) <= MaxTokenLength;

    /// <summary>
    /// Whether the iroh details form a usable group: a valid id, and a relay and token that are valid
    /// when present. A relay or token without an id is not usable.
    /// </summary>
    public static bool AreValid(string? id, string? relay, string? token) =>
        IsValidId(id) && (relay is null || IsValidRelay(relay)) && (token is null || IsValidToken(token));
}
