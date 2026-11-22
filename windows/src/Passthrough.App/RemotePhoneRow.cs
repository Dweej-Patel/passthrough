namespace Passthrough.App;

/// <summary>A phone allowed to open shells on this PC, as Settings ▸ Remote access lists it.</summary>
public sealed class RemotePhoneRow(string phoneId, string label, string pairingSlot, bool connected, int sessions, bool screen = false, bool screenAvailable = false, bool share = false)
{
    /// <summary>It may give another of the owner's computers access to this PC (off unless the owner turns it on here).</summary>
    public bool Share { get; } = share;

    /// <summary>It may see the screen (through Remote Desktop; Windows still asks for the password).</summary>
    public bool Screen { get; } = screen;

    /// <summary>The Screen switch can be turned on: Screen is set up and this account consented (it can always be turned off).</summary>
    public bool ScreenSwitchEnabled { get; } = screenAvailable || screen;

    public string PhoneId { get; } = phoneId;
    public string Title { get; } = label;

    public string Detail { get; } = (connected, sessions) switch
    {
        (true, 0) => "Connected",
        (true, 1) => "Connected · 1 shell open",
        (true, var n) => $"Connected · {n} shells open",
        (false, 0) => "Not connected",
        (false, 1) => "1 shell open",
        (false, var n) => $"{n} shells open",
    };

    /// <summary>Stop ends its connections and the shells it opened; it keeps its access.</summary>
    public bool CanStop { get; } = connected || sessions > 0;

    public string Glyph => pairingSlot.StartsWith("token.ipad.", StringComparison.Ordinal) ? Glyphs.Tablet : Glyphs.Phone;
}
