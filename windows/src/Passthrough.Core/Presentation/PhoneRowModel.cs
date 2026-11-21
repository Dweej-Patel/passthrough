using Passthrough.Core.Protocol;
using Passthrough.Core.Session;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Presentation;

/// <summary>
/// What one phone's row in the flyout shows, worked out from a <see cref="PhoneEntry"/>: the texts, and which lines and
/// buttons are visible. The App only maps the booleans to visibility.
/// </summary>
public sealed record PhoneRowModel
{
    public required string Id { get; init; }

    /// <summary>Which attachment of the phone the row shows; a code typed into it is addressed to this one.</summary>
    public required long Attachment { get; init; }

    /// <summary>"●" for the active phone, "○" for the others.</summary>
    public required string Marker { get; init; }

    /// <summary>The phone's own name (live, else the one saved when it was last paired), else an Android phone's model, else its kind: "iPhone", "Android phone", "iPad".</summary>
    public required string Title { get; init; }

    /// <summary>The hardware id (an iPhone's or iPad's UDID prefix, an Android serial), after the kind when the title is a name: "iPhone · 00008110…".</summary>
    public required string Detail { get; init; }

    public required string StateText { get; init; }

    /// <summary>iPhone, Android phone or iPad, for the row's picture.</summary>
    public required PhoneKind Kind { get; init; }

    /// <summary>The phone this PC is using; its picture is filled in.</summary>
    public required bool IsActive { get; init; }

    /// <summary>What the state means at a glance: paired is good, the active phone waiting for its code needs a person, a failed channel is a problem.</summary>
    public required RowTone Tone { get; init; }

    /// <summary>Something is under way (the channel is opening, a code is being checked): a spinner stands in for the dot.</summary>
    public required bool Busy { get; init; }

    /// <summary>"{carrier} · {radio} · {battery}", see <see cref="Presentation.StatusLine"/>.</summary>
    public required string StatusLine { get; init; }

    /// <summary>Connections and bytes carried, for the active phone once it is paired.</summary>
    public required string ActivityLine { get; init; }

    /// <summary>A pairing failure, an error, or why the channel dropped while it is retried.</summary>
    public required string Message { get; init; }

    public bool ShowStatus => StatusLine.Length > 0;
    public bool ShowActivity => ActivityLine.Length > 0;
    public bool ShowMessage => Message.Length > 0;

    /// <summary>The code box and Pair button: the active phone while it has no pairing (also while its channel is still opening).</summary>
    public required bool ShowPair { get; init; }

    /// <summary>Pair can be pressed: no code is in flight, and the phone is unpaired (a code typed before the welcome is held for it).</summary>
    public required bool CanPair { get; init; }

    /// <summary>[Try again]: the active phone, once its channel failed for good.</summary>
    public required bool ShowRetry { get; init; }

    /// <summary>[Use this phone]: any other phone that can be made active.</summary>
    public required bool ShowUse { get; init; }

    /// <summary>Forget pairing: this PC holds a token for the phone, whatever its state.</summary>
    public required bool ShowForget { get; init; }

    public static PhoneRowModel From(PhoneEntry e)
    {
        var kind = e.Device.Kind.Label();
        // Android: the serial identifies the phone and the model names it until the phone says its own name. iPhone and
        // iPad: the UDID prefix is the label.
        var android = e.Device.Transport == WatchTransport.Adb && e.Device.Id.StartsWith("adb:", StringComparison.Ordinal);
        var id = android ? e.Device.Id["adb:".Length..] : e.Device.Label;
        var model = android && e.Device.Label != id ? NonEmpty(e.Device.Label) : null;
        var name = NonEmpty(e.Status?.DeviceName) ?? NonEmpty(e.SavedName) ?? model;
        var unpaired = e.State == PhoneState.NotPaired || (e.State == PhoneState.Connecting && !e.HasPairing);
        return new PhoneRowModel
        {
            Id = e.Device.Id,
            Attachment = e.Attachment,
            Marker = e.IsActive ? "●" : "○",
            Title = name ?? kind,
            Detail = name is null ? id : $"{kind} · {id}",
            StateText = e.State switch
            {
                PhoneState.NotPaired => "Not paired",
                PhoneState.Connecting => "Connecting…",
                PhoneState.Paired => "Paired",
                PhoneState.Pairing => "Pairing…",
                PhoneState.Failed => "Failed",
                PhoneState.RemoteOnlyLater => "Not supported yet",
                _ => "",
            },
            Kind = e.Device.Kind,
            IsActive = e.IsActive,
            Tone = e.State switch
            {
                PhoneState.Paired => RowTone.Good,
                PhoneState.Failed => RowTone.Problem,
                PhoneState.NotPaired when e.IsActive => RowTone.Attention,
                _ => RowTone.Neutral,
            },
            Busy = e.State is PhoneState.Connecting or PhoneState.Pairing,
            StatusLine = Presentation.StatusLine.Format(e.Status),
            ActivityLine = e.IsActive && e.State == PhoneState.Paired
                ? $"{e.Active} {(e.Active == 1 ? "connection" : "connections")} · ↓ {Format.Bytes(e.Rx)} ↑ {Format.Bytes(e.Tx)}"
                : "",
            Message = e.Message ?? "",
            ShowPair = e.IsActive && (unpaired || e.State == PhoneState.Pairing),
            CanPair = unpaired,
            ShowRetry = e.IsActive && e.State == PhoneState.Failed,
            ShowUse = !e.IsActive && e.State != PhoneState.RemoteOnlyLater,
            ShowForget = e.HasPairing,
        };
    }

    private static string? NonEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s;
}
