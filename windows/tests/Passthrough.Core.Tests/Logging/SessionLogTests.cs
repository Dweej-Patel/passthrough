using Passthrough.Core.Control;
using Passthrough.Core.Logging;
using Passthrough.Core.Session;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Logging;

public class SessionLogTests
{
    private static readonly PhoneDevice IPhone = new("usbmux:3", PhoneKind.IPhone, "00008110…", "token.iphone.A",
        WatchTransport.UsbMux, (_, _) => throw new InvalidOperationException());
    private static readonly PhoneDevice Android = new("adb:R58", PhoneKind.Android, "Pixel", "token.android.R58",
        WatchTransport.Adb, (_, _) => throw new InvalidOperationException());

    private static readonly WatchStatus Idle = new(WatchState.Idle);

    private static PhoneEntry E(PhoneDevice d, PhoneState s, bool active = false, string? message = null, DeviceStatus? status = null) =>
        new(d, s, active, status, 0, 0, 0, message, false, 1);

    [Fact]
    public void FirstSnapshot_LogsTheWatchersThatAreNotIdle()
    {
        var after = new SessionState([], new(WatchState.NotInstalled, UsbMuxWatcher.NotInstalledHint), new(WatchState.Starting));
        Assert.Equal([$"usbmux watcher: NotInstalled ({UsbMuxWatcher.NotInstalledHint})", "adb watcher: Starting"], SessionLog.Changes(null, after));
    }

    [Fact]
    public void WatcherChanges_AndTheirHints()
    {
        var before = new SessionState([], new(WatchState.Starting), new(WatchState.Watching));
        var after = new SessionState([], new(WatchState.Watching), new(WatchState.Watching, AdbWatcher.UnauthorizedHint));
        Assert.Equal(["usbmux watcher: Watching", $"adb watcher: Watching ({AdbWatcher.UnauthorizedHint})"], SessionLog.Changes(before, after));
    }

    [Fact]
    public void Phones_AttachedDetachedAndTheirStates_WithoutWhatThePhoneSays()
    {
        var before = new SessionState([E(Android, PhoneState.Paired)], Idle, Idle);
        var after = new SessionState([E(IPhone, PhoneState.Connecting, active: true)], Idle, Idle);
        Assert.Equal([
            "detached adb:R58 (Android phone)",
            "attached usbmux:3 (iPhone)",
            "usbmux:3 (iPhone): Connecting, active",
        ], SessionLog.Changes(before, after));

        var paired = new SessionState([E(IPhone, PhoneState.Paired, active: true,
            status: new DeviceStatus("Dee's iPhone", "5G", "Carrier", 0.5, null, null, null))], Idle, Idle);
        var lines = SessionLog.Changes(after, paired);
        Assert.Equal(["usbmux:3 (iPhone): Paired, active"], lines);

        // Status ticks alone log nothing.
        var tick = new SessionState([E(IPhone, PhoneState.Paired, active: true,
            status: new DeviceStatus("Dee's iPhone", "LTE", "Carrier", 0.49, null, null, null))], Idle, Idle);
        Assert.Empty(SessionLog.Changes(paired, tick));
    }

    [Fact]
    public void AFailure_LogsItsMessage()
    {
        var before = new SessionState([E(IPhone, PhoneState.Connecting, active: true)], Idle, Idle);
        var after = new SessionState([E(IPhone, PhoneState.Failed, active: true, message: "Couldn't read this PC's saved pairings or settings. Try again.")], Idle, Idle);
        Assert.Equal(["usbmux:3 (iPhone): Failed, active: Couldn't read this PC's saved pairings or settings. Try again."], SessionLog.Changes(before, after));
    }

    [Fact]
    public void Startup_NamesTheVersions() =>
        Assert.Equal("Passthrough 1.2.3 starting on Microsoft Windows NT 10.0.22631.0 (X64), .NET 10.0.0",
            SessionLog.Startup("1.2.3", "Microsoft Windows NT 10.0.22631.0", "X64", ".NET 10.0.0"));
}
