using Passthrough.Core.Session;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Presentation;

/// <summary>
/// The top of the flyout: what this PC is doing with the phone it uses, in two lines, as the Mac's panel says it.
/// <paramref name="Kind"/> picks the picture (null with no phone in use) and <paramref name="Connected"/> fills it in.
/// </summary>
public sealed record FlyoutHeader(string Title, string Subtitle, PhoneKind? Kind, bool Connected)
{
    public const string NoPhoneTitle = "No phone attached";
    public const string NoPhoneSubtitle = "Plug in an iPhone or Android phone with its cable";

    public static FlyoutHeader For(SessionState state)
    {
        if (state.Phones.FirstOrDefault(p => p.IsActive) is not { } active)
        {
            return state.Phones.Count == 0
                ? new FlyoutHeader(NoPhoneTitle, NoPhoneSubtitle, null, false)
                : new FlyoutHeader("No phone in use", state.Phones.Count == 1 ? "1 attached" : $"{state.Phones.Count} attached", null, false);
        }

        var name = PhoneRowModel.From(active).Title;
        var kind = active.Device.Kind;
        var status = StatusLine.Format(active.Status);
        // As the row does: a phone with no pairing shows its code box while its channel is still opening, so it is
        // being paired, not connected to.
        if (active.State == PhoneState.Connecting && !active.HasPairing)
            return new FlyoutHeader($"Pair with {name}", $"Type the code shown on the {kind.Label()}", kind, false);
        return active.State switch
        {
            PhoneState.Paired => new FlyoutHeader($"Connected to {name}", status.Length > 0 ? status : "Paired over the cable", kind, true),
            PhoneState.Connecting => new FlyoutHeader($"Connecting to {name}…", "Reaching it over the cable", kind, false),
            PhoneState.NotPaired => new FlyoutHeader($"Pair with {name}", $"Type the code shown on the {kind.Label()}", kind, false),
            PhoneState.Pairing => new FlyoutHeader($"Pair with {name}", "Checking the code…", kind, false),
            PhoneState.Failed => new FlyoutHeader($"Can't connect to {name}", "See below, then try again", kind, false),
            _ => new FlyoutHeader(name, "Not supported yet", kind, false),
        };
    }
}
