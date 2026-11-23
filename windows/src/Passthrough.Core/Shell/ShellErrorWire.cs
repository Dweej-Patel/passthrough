namespace Passthrough.Core.Shell;

/// <summary>The wire names of <see cref="ShellError"/>.</summary>
public static class ShellErrorWire
{
    private static readonly (ShellError Error, string Wire)[] Names =
    [
        (ShellError.NotAuthorized, "not_authorized"),
        (ShellError.TooManySessions, "too_many_sessions"),
        (ShellError.NoSuchSession, "no_such_session"),
        (ShellError.BadRequest, "bad_request"),
        (ShellError.ScreenNotAllowed, "screen_not_allowed"),
        (ShellError.ScreenUnavailable, "screen_unavailable"),
        (ShellError.ScreenVideoUnavailable, "screen_video_unavailable"),
        (ShellError.TooManyScreens, "too_many_screens"),
        (ShellError.NotAllowed, "not_allowed"),
        (ShellError.VpnNotSetUp, "vpn_not_set_up"),
        (ShellError.ScreenOnly, "screen_only"),
        (ShellError.PassNotSaved, "pass_not_saved"),
        (ShellError.SignedOut, "signed_out"),
        (ShellError.RdpUnavailable, "rdp_unavailable"),
        (ShellError.TryLater, "try_later"),
        (ShellError.TooManyComputers, "too_many_computers"),
        (ShellError.PassConflict, "pass_conflict"),
        (ShellError.NoScreenView, "no_screen_view"),
        (ShellError.ClipSyncOff, "clip_sync_off"),
        (ShellError.ClipSyncUnavailable, "clip_sync_unavailable"),
    ];

    /// <summary>Every wire name, in declaration order.</summary>
    public static IEnumerable<string> All => Names.Select(n => n.Wire);

    public static string ToWire(this ShellError error) => Names.First(n => n.Error == error).Wire;

    /// <summary>A reason this side doesn't know reads as <see cref="ShellError.BadRequest"/>, as the phones read one after <c>ready</c>.</summary>
    public static ShellError Parse(string? wire)
    {
        foreach (var (error, name) in Names)
            if (name == wire) return error;
        return ShellError.BadRequest;
    }

    /// <summary>Whether <paramref name="wire"/> is a reason this side knows.</summary>
    public static bool IsKnown(string? wire) => Names.Any(n => n.Wire == wire);
}
