using System.Text;

namespace Passthrough.Core.Transport;

/// <summary>A phone the PC can reach, and the way to reach it. Two devices are equal when their <see cref="Id"/> matches.</summary>
public sealed class PhoneDevice : IEquatable<PhoneDevice>
{
    /// <summary>usbmux ProductID of an iPad (an iPhone's is 0x12A8).</summary>
    public const int IPadProductId = 0x12AB;

    public PhoneDevice(string id, PhoneKind kind, string label, string pairingSlot, WatchTransport transport,
        Func<int, CancellationToken, Task<Stream>> connect)
    {
        Id = id;
        Kind = kind;
        Label = label;
        PairingSlot = pairingSlot;
        Transport = transport;
        Connect = connect;
    }

    /// <summary>Unique among attached phones: "usbmux:3" or "adb:R58M123".</summary>
    public string Id { get; }

    public PhoneKind Kind { get; }

    /// <summary>Short hardware label for logs and lists: the UDID's first eight characters and an ellipsis, or the Android model.</summary>
    public string Label { get; }

    /// <summary>Names the stored pairing token: one per phone, keyed by the iPhone or iPad UDID or the Android serial.</summary>
    public string PairingSlot { get; }

    public WatchTransport Transport { get; }

    /// <summary>Opens a stream to a port on the phone's loopback; the caller owns the stream.</summary>
    public Func<int, CancellationToken, Task<Stream>> Connect { get; }

    /// <summary>Can carry the PC's internet. An iPad cannot: it is a remote only.</summary>
    public bool CanRoute => Kind != PhoneKind.IPad;

    /// <summary>An iPhone or iPad on the cable, as usbmuxd reports it.</summary>
    public static PhoneDevice FromUsbMux(UsbMuxDevice d, UsbMuxClient client)
    {
        var isIPad = d.ProductId == IPadProductId;
        return new PhoneDevice(
            $"usbmux:{d.DeviceId}",
            isIPad ? PhoneKind.IPad : PhoneKind.IPhone,
            d.Udid[..Math.Min(8, d.Udid.Length)] + "…",
            SlotFor(isIPad ? PhoneKind.IPad : PhoneKind.IPhone, d.Udid),
            WatchTransport.UsbMux,
            (port, ct) => client.ConnectAsync(d.DeviceId, port, ct));
    }

    /// <summary>An Android phone on the cable, as adb reports it.</summary>
    public static PhoneDevice FromAdb(AdbDevice d, AdbClient client) =>
        new($"adb:{d.Serial}", PhoneKind.Android, d.Model ?? d.Serial, SlotFor(PhoneKind.Android, d.Serial),
            WatchTransport.Adb, (port, ct) => client.ConnectAsync(d.Serial, port, ct));

    /// <summary>Whether a secret slot holds a cable pairing token (<c>token.*</c>), not some other secret.</summary>
    public static bool IsPairingSlot(string slot) => slot.StartsWith("token.", StringComparison.Ordinal);

    /// <summary>
    /// The pairing slot for a phone of <paramref name="kind"/> with this UDID or serial: <c>token.iphone.</c>,
    /// <c>token.ipad.</c> or <c>token.android.</c>, then the id as <see cref="SlotSafe"/> leaves it. When that filter
    /// changed the id, <c>-</c> and the first 8 hex digits of the SHA-256 of the whole original id follow, so ids that
    /// filter to the same text ("A+B" and "AB") keep separate slots. Ids the filter leaves alone (every normal UDID and
    /// serial) keep the plain form. Slots stay on this PC, so they need not match the Mac's.
    /// </summary>
    public static string SlotFor(PhoneKind kind, string hardwareId)
    {
        var prefix = kind switch
        {
            PhoneKind.IPhone => "token.iphone.",
            PhoneKind.IPad => "token.ipad.",
            _ => "token.android.",
        };
        var safe = SlotSafe(hardwareId);
        if (safe == hardwareId) return prefix + safe;
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(hardwareId)));
        return prefix + safe + "-" + hash[..8].ToLowerInvariant();
    }

    /// <summary>
    /// A hardware id as it may appear in a credential account name: anything but letters, digits, combining marks,
    /// "-", "_" and "." is dropped. Works per Unicode scalar, as Swift's Character does (marks stay with their letter).
    /// </summary>
    private static string SlotSafe(string id)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var r in id.EnumerateRunes())
        {
            var keep = Rune.IsLetterOrDigit(r) || Rune.IsNumber(r) || r.Value is '-' or '_' or '.'
                || Rune.GetUnicodeCategory(r) is System.Globalization.UnicodeCategory.NonSpacingMark
                    or System.Globalization.UnicodeCategory.SpacingCombiningMark
                    or System.Globalization.UnicodeCategory.EnclosingMark;
            if (keep) sb.Append(r.ToString());
        }
        return sb.ToString();
    }

    public bool Equals(PhoneDevice? other) => other is not null && Id == other.Id;

    public override bool Equals(object? obj) => Equals(obj as PhoneDevice);

    public override int GetHashCode() => Id.GetHashCode();

    public override string ToString() => Id;
}
