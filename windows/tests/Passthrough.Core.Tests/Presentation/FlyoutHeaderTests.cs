using Passthrough.Core.Control;
using Passthrough.Core.Presentation;
using Passthrough.Core.Session;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Presentation;

public class FlyoutHeaderTests
{
    private static readonly PhoneDevice IPhone = new("usbmux:3", PhoneKind.IPhone, "00008110…", "token.iphone.00008110-AAAA",
        WatchTransport.UsbMux, (_, _) => throw new InvalidOperationException());
    private static readonly PhoneDevice Android = new("adb:R58M123", PhoneKind.Android, "Pixel 8", "token.android.R58M123",
        WatchTransport.Adb, (_, _) => throw new InvalidOperationException());
    private static readonly PhoneDevice IPad = new("usbmux:4", PhoneKind.IPad, "00008027…", "token.ipad.00008027-BBBB",
        WatchTransport.UsbMux, (_, _) => throw new InvalidOperationException());
    private static readonly WatchStatus Watching = new(WatchState.Watching, null);

    private static PhoneEntry Entry(PhoneDevice d, PhoneState state, bool active = true, DeviceStatus? status = null, bool? hasPairing = null) =>
        new(d, state, active, status, 0, 0, 0, null, hasPairing ?? state == PhoneState.Paired, 7);

    private static FlyoutHeader For(params PhoneEntry[] phones) => FlyoutHeader.For(new SessionState(phones, Watching, Watching));

    [Fact]
    public void NoPhone_SaysToPlugOneIn()
    {
        Assert.Equal(new FlyoutHeader(FlyoutHeader.NoPhoneTitle, FlyoutHeader.NoPhoneSubtitle, null, false), For());
    }

    [Fact]
    public void PhonesButNoneInUse_CountsThem()
    {
        Assert.Equal(new FlyoutHeader("No phone in use", "1 attached", null, false), For(Entry(IPad, PhoneState.NotPaired, active: false)));
        Assert.Equal("2 attached", For(Entry(IPad, PhoneState.NotPaired, active: false), Entry(IPad, PhoneState.NotPaired, active: false)).Subtitle);
    }

    [Fact]
    public void Paired_NamesThePhone_AndShowsItsLiveFacts()
    {
        var status = new DeviceStatus("Dee's iPhone", "5G", "Jio", 0.82, null, null, null);
        Assert.Equal(new FlyoutHeader("Connected to Dee's iPhone", "Jio · 5G · 82%", PhoneKind.IPhone, true), For(Entry(IPhone, PhoneState.Paired, status: status)));
        // Before the first status arrives there are no facts to show.
        Assert.Equal(new FlyoutHeader("Connected to iPhone", "Paired over the cable", PhoneKind.IPhone, true), For(Entry(IPhone, PhoneState.Paired)));
    }

    [Theory]
    [InlineData(PhoneState.Connecting, "Pair with Pixel 8", "Type the code shown on the Android phone")] // no pairing: the code box is up
    [InlineData(PhoneState.NotPaired, "Pair with Pixel 8", "Type the code shown on the Android phone")]
    [InlineData(PhoneState.Pairing, "Pair with Pixel 8", "Checking the code…")]
    [InlineData(PhoneState.Failed, "Can't connect to Pixel 8", "See below, then try again")]
    public void NotYetPaired_SaysWhatIsHappening(PhoneState state, string title, string subtitle)
    {
        Assert.Equal(new FlyoutHeader(title, subtitle, PhoneKind.Android, false), For(Entry(Android, state)));
    }

    [Fact]
    public void Connecting_WithAPairing_SaysSo()
    {
        Assert.Equal(new FlyoutHeader("Connecting to Pixel 8…", "Reaching it over the cable", PhoneKind.Android, false),
            For(Entry(Android, PhoneState.Connecting, hasPairing: true)));
    }

    [Fact]
    public void TheActivePhoneIsTheOneDescribed()
    {
        var header = For(Entry(IPhone, PhoneState.Paired, active: false), Entry(Android, PhoneState.NotPaired));
        Assert.Equal(("Pair with Pixel 8", PhoneKind.Android), (header.Title, header.Kind));
    }
}
