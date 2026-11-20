using Passthrough.Core.Control;
using Passthrough.Core.Presentation;
using Passthrough.Core.Session;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Presentation;

public class WatcherHintsTests
{
    private static readonly PhoneDevice IPhone = new("usbmux:3", PhoneKind.IPhone, "00008110…", "token.iphone.A",
        WatchTransport.UsbMux, (_, _) => throw new InvalidOperationException());
    private static readonly PhoneDevice Android = new("adb:R58", PhoneKind.Android, "Pixel", "token.android.R58",
        WatchTransport.Adb, (_, _) => throw new InvalidOperationException());

    private static readonly WatchStatus UsbMissing = new(WatchState.NotInstalled, UsbMuxWatcher.NotInstalledHint);
    private static readonly WatchStatus AdbMissing = new(WatchState.NotInstalled, AdbWatcher.NotInstalledHint);

    private static SessionState State(WatchStatus usb, WatchStatus adb, params PhoneDevice[] phones) =>
        new([.. phones.Select(p => new PhoneEntry(p, PhoneState.NotPaired, false, null, 0, 0, 0, null, false, 1))], usb, adb);

    [Fact]
    public void Watching_WithoutAHint_SaysNothing() =>
        Assert.Empty(WatcherHints.For(State(new(WatchState.Watching), new(WatchState.Starting))));

    [Fact]
    public void NothingAttached_BothInstallHints()
    {
        Assert.Equal([UsbMuxWatcher.NotInstalledHint, AdbWatcher.NotInstalledHint], WatcherHints.For(State(UsbMissing, AdbMissing)));
    }

    [Fact]
    public void AnInstallHint_IsDropped_WhileAPhoneOfTheOtherKindIsAttached()
    {
        Assert.Equal([UsbMuxWatcher.NotInstalledHint], WatcherHints.For(State(UsbMissing, AdbMissing, IPhone)));
        Assert.Equal([AdbWatcher.NotInstalledHint], WatcherHints.For(State(UsbMissing, AdbMissing, Android)));
    }

    [Fact]
    public void Unavailable_HasALineForEachTransport()
    {
        var hints = WatcherHints.For(State(new(WatchState.Unavailable), new(WatchState.Unavailable), IPhone, Android));
        Assert.Equal([WatcherHints.UsbMuxUnavailable, WatcherHints.AdbUnavailable], hints);
    }

    [Fact]
    public void AWatchersOwnHint_IsShown()
    {
        var hints = WatcherHints.For(State(new(WatchState.Watching), new(WatchState.Watching, AdbWatcher.UnauthorizedHint), IPhone));
        Assert.Equal([AdbWatcher.UnauthorizedHint], hints);
    }

    [Fact]
    public void UsbMuxInstallHint_CoversAppleDevicesInstalledButNotRunning() =>
        Assert.Contains("open", UsbMuxWatcher.NotInstalledHint);
}
