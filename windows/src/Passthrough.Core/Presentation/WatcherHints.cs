using Passthrough.Core.Session;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Presentation;

/// <summary>What the flyout tells the user to do about the watchers, one line each.</summary>
public static class WatcherHints
{
    /// <summary>usbmuxd answered and then failed (refused the watch, fell silent, dropped it).</summary>
    public const string UsbMuxUnavailable =
        "Apple Devices isn't answering. Open Apple Devices; if this lasts, restart Apple Mobile Device Service or the PC.";

    /// <summary>adb was found but its server won't start or answer.</summary>
    public const string AdbUnavailable =
        "adb was found but isn't answering. Passthrough keeps trying; if this lasts, run \"adb kill-server\" and wait.";

    /// <summary>
    /// A watcher's own hint (install, allow USB debugging), else a line for an <see cref="WatchState.Unavailable"/>
    /// watcher. An install hint is left out while a phone of the other kind is attached: someone using only an iPhone
    /// isn't told to install adb, and the reverse.
    /// </summary>
    public static IReadOnlyList<string> For(SessionState state)
    {
        var hints = new List<string>();
        Add(hints, state, WatchTransport.UsbMux, state.UsbMux, UsbMuxUnavailable);
        Add(hints, state, WatchTransport.Adb, state.Adb, AdbUnavailable);
        return hints;
    }

    private static void Add(List<string> hints, SessionState state, WatchTransport transport, WatchStatus status, string unavailable)
    {
        if (status.State == WatchState.NotInstalled && state.Phones.Any(p => p.Device.Transport != transport)) return;
        if (!string.IsNullOrEmpty(status.Hint)) hints.Add(status.Hint);
        else if (status.State == WatchState.Unavailable) hints.Add(unavailable);
    }
}
