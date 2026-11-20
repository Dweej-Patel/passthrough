using Passthrough.Core.Transport;

namespace Passthrough.Core.Presentation;

/// <summary>One stored pairing as Settings lists it: the slot to forget, a title and the short hardware id.</summary>
public sealed record PairedPhone(string Slot, string Title, string Detail)
{
    /// <summary>
    /// One entry per slot, in the order given. The title is the phone's saved name, else its kind ("iPhone", "iPad",
    /// "Android phone"); the detail is the short id (a UDID's first eight characters, an Android serial), after the kind
    /// when the title is a name, as the flyout rows do.
    /// </summary>
    public static IReadOnlyList<PairedPhone> List(IReadOnlyList<string> slots, Func<string, string?> savedName) =>
        [.. slots.Select(slot => For(slot, savedName(slot)))];

    private static PairedPhone For(string slot, string? name)
    {
        (PhoneKind Kind, string Id)? parsed =
            slot.StartsWith("token.iphone.", StringComparison.Ordinal) ? (PhoneKind.IPhone, Short(slot["token.iphone.".Length..])) :
            slot.StartsWith("token.ipad.", StringComparison.Ordinal) ? (PhoneKind.IPad, Short(slot["token.ipad.".Length..])) :
            slot.StartsWith("token.android.", StringComparison.Ordinal) ? (PhoneKind.Android, slot["token.android.".Length..]) :
            null;
        if (parsed is not { } p) return new PairedPhone(slot, name ?? slot, "");
        var kind = p.Kind.Label();
        return string.IsNullOrWhiteSpace(name)
            ? new PairedPhone(slot, kind, p.Id)
            : new PairedPhone(slot, name, $"{kind} · {p.Id}");
    }

    /// <summary>A UDID as <see cref="PhoneDevice.FromUsbMux"/> labels it: the first eight characters and an ellipsis.</summary>
    private static string Short(string udid) => udid.Length > 8 ? udid[..8] + "…" : udid;
}
