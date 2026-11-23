using System.Security.Cryptography;
using System.Text;

namespace Passthrough.Core.Shell.Access;

/// <summary>
/// What a shell grant tells a phone besides its key: where this PC's shell listens and which certificate it
/// presents, its name, and how to reach it over iroh (protocol/README.md, control channel, <c>shellGrant</c>).
/// </summary>
public sealed record GrantContents
{
    /// <summary>
    /// The certificate hash sent while this PC has no listener of its own: sixty-four zeros, which no certificate
    /// can match. A client must never read it as "no pin"; it means the local path doesn't exist yet.
    /// </summary>
    public static readonly string NoListenerPin = new('0', 64);

    /// <summary>SHA-256 of the listener's certificate, 64 lowercase hex.</summary>
    public required string CertSHA256 { get; init; }
    public int Port { get; init; } = RemoteShell.DefaultPort;
    /// <summary>Where to dial this PC; not part of <see cref="Fingerprint"/> (phones learn them from <c>macInfo</c>).</summary>
    public IReadOnlyList<string> Addresses { get; init; } = [];
    /// <summary>This PC's name, as its DNS-SD instance name will be: one source for both.</summary>
    public required string HostName { get; init; }
    public string? IrohId { get; init; }
    public string? IrohRelay { get; init; }
    /// <summary>The relay's token, when the relay needs one. Never logged.</summary>
    public string? RelayToken { get; init; }

    /// <summary>
    /// The Mac's grant contents string (<c>ShellGrantLedger.contents</c> in MacSessionPolicy.swift): each of
    /// certificate, port, name, iroh id, relay and token as <c>length:value</c>, <c>-</c> for an absent one.
    /// </summary>
    internal string ContentsString() =>
        string.Concat(new[] { CertSHA256, Port.ToString(System.Globalization.CultureInfo.InvariantCulture), HostName, IrohId ?? "-", IrohRelay ?? "-", RelayToken ?? "-" }
            .Select(v => $"{Encoding.UTF8.GetByteCount(v)}:{v}"));

    /// <summary>
    /// What tells one grant's contents from another's: the SHA-256 (hex) of <see cref="ContentsString"/>, so the
    /// relay token never sits in a field that is compared or printed.
    /// </summary>
    public string Fingerprint => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(ContentsString()))).ToLowerInvariant();

    /// <summary>Never shows the relay token.</summary>
    public override string ToString() =>
        $"GrantContents(cert: {CertSHA256[..Math.Min(16, CertSHA256.Length)]}…, port: {Port}, host: {HostName}, addresses: {Addresses.Count}, " +
        $"irohID: {IrohId ?? "none"}, irohRelay: {IrohRelay ?? "none"}, relayToken: {(RelayToken is null ? "none" : "(redacted)")})";
}
