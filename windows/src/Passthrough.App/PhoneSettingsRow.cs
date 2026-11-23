using Microsoft.UI.Xaml;
using Passthrough.Core.Pipe;
using Passthrough.Core.Presentation;

namespace Passthrough.App;

/// <summary>
/// One phone in Settings ▸ Remote access, whatever it holds: its cable pairing (Forget…), its access here (Screen,
/// Share, Stop, Revoke…), or both. One row per phone instead of a list of pairings and another of access.
/// </summary>
public sealed class PhoneSettingsRow
{
    public PhoneSettingsRow(PairedPhone? paired, PipeDevice? access, bool connected, int sessions, bool screenAvailable)
    {
        Slot = paired?.Slot ?? access?.PairingSlot;
        PhoneId = access?.Phone;
        Title = access?.Label is { Length: > 0 } label ? label : paired?.Title ?? "Phone";
        Screen = access?.Screen == true;
        Share = access?.Share == true;
        ScreenSwitchEnabled = screenAvailable || Screen;
        CanStop = access is not null && (connected || sessions > 0);
        AccessVisibility = access is null ? Visibility.Collapsed : Visibility.Visible;
        ForgetVisibility = paired is null ? Visibility.Collapsed : Visibility.Visible;
        Detail = string.Join(" · ", new[]
        {
            paired is null ? "Not paired over the cable" : paired.Detail,
            access is null ? "No access yet: plug it in with Remote access on" : null,
            access is not null && access.Viewing ? "Viewing the screen" : null,
            access is not null && !screenAvailable && access.Screen != true ? "Screen: set up the screen above first" : null,
            access is not null && connected ? "Connected" : null,
            sessions switch { 0 => null, 1 => "1 shell open", var n => $"{n} shells open" },
        }.Where(part => !string.IsNullOrEmpty(part)));
    }

    public string? Slot { get; }
    public string? PhoneId { get; }
    public string Title { get; }
    public string Detail { get; }
    public bool Screen { get; }
    public bool Share { get; }
    public bool ScreenSwitchEnabled { get; }
    public bool CanStop { get; }
    public Visibility AccessVisibility { get; }
    public Visibility ForgetVisibility { get; }
    public bool HasAccess => PhoneId is not null;

    public string ScreenTip => ScreenSwitchEnabled
        ? "Let it see and control this PC's screen. Windows still asks for your password."
        : "Set up the screen above first.";

    public string Glyph => Slot?.StartsWith("token.ipad.", StringComparison.Ordinal) == true ? Glyphs.Tablet : Glyphs.Phone;

    public string ScreenName => $"Let {Title} see the screen";
    public string ShareName => $"Let {Title} share access with your other computers";
    public string StopName => $"Stop {Title}";
    public string RevokeName => $"Revoke {Title}";
    public string ForgetName => $"Forget {Title}";
}
