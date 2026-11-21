using Passthrough.Core.Control;
using Passthrough.Core.Presentation;
using Passthrough.Core.Session;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Presentation;

public class PhoneRowModelTests
{
    private static readonly PhoneDevice IPhone = new("usbmux:3", PhoneKind.IPhone, "00008110…", "token.iphone.00008110-AAAA",
        WatchTransport.UsbMux, (_, _) => throw new InvalidOperationException());
    private static readonly PhoneDevice Android = new("adb:R58M123", PhoneKind.Android, "Pixel 8", "token.android.R58M123",
        WatchTransport.Adb, (_, _) => throw new InvalidOperationException());
    private static readonly PhoneDevice IPad = new("usbmux:4", PhoneKind.IPad, "00008027…", "token.ipad.00008027-BBBB",
        WatchTransport.UsbMux, (_, _) => throw new InvalidOperationException());

    private static PhoneEntry Entry(PhoneDevice d, PhoneState state, bool active = true, bool hasPairing = false,
        DeviceStatus? status = null, string? message = null, string? savedName = null, int connections = 0, long rx = 0, long tx = 0) =>
        new(d, state, active, status, rx, tx, connections, message, hasPairing, 7, savedName);

    [Fact]
    public void Ids_AndMarker()
    {
        var active = PhoneRowModel.From(Entry(IPhone, PhoneState.NotPaired));
        var other = PhoneRowModel.From(Entry(Android, PhoneState.Paired, active: false, hasPairing: true));
        Assert.Equal(("usbmux:3", 7L, "●"), (active.Id, active.Attachment, active.Marker));
        Assert.Equal("○", other.Marker);
    }

    [Theory]
    [InlineData(PhoneState.NotPaired, "Not paired")]
    [InlineData(PhoneState.Connecting, "Connecting…")]
    [InlineData(PhoneState.Paired, "Paired")]
    [InlineData(PhoneState.Pairing, "Pairing…")]
    [InlineData(PhoneState.Failed, "Failed")]
    [InlineData(PhoneState.RemoteOnlyLater, "Not supported yet")]
    public void StateText(PhoneState state, string text) => Assert.Equal(text, PhoneRowModel.From(Entry(IPhone, state)).StateText);

    [Theory]
    [InlineData(PhoneState.Paired, true, RowTone.Good, false)]
    [InlineData(PhoneState.Paired, false, RowTone.Good, false)]
    [InlineData(PhoneState.NotPaired, true, RowTone.Attention, false)]
    [InlineData(PhoneState.NotPaired, false, RowTone.Neutral, false)] // only the phone in use asks for its code
    [InlineData(PhoneState.Connecting, true, RowTone.Neutral, true)]
    [InlineData(PhoneState.Pairing, true, RowTone.Neutral, true)]
    [InlineData(PhoneState.Failed, true, RowTone.Problem, false)]
    [InlineData(PhoneState.RemoteOnlyLater, false, RowTone.Neutral, false)]
    public void Tone_AndBusy(PhoneState state, bool active, RowTone tone, bool busy)
    {
        var row = PhoneRowModel.From(Entry(IPhone, state, active: active));
        Assert.Equal((tone, busy, active, PhoneKind.IPhone), (row.Tone, row.Busy, row.IsActive, row.Kind));
    }

    [Fact]
    public void Title_LiveNameFirst_ThenSavedName_ThenTheKind()
    {
        var live = PhoneRowModel.From(Entry(IPhone, PhoneState.Paired, hasPairing: true, savedName: "Old name",
            status: new DeviceStatus("Dee's iPhone", null, null, null, null, null, null)));
        var saved = PhoneRowModel.From(Entry(IPhone, PhoneState.Paired, active: false, hasPairing: true, savedName: "Dee's iPhone"));
        var unknown = PhoneRowModel.From(Entry(IPhone, PhoneState.NotPaired));
        var emptyNames = PhoneRowModel.From(Entry(IPhone, PhoneState.Paired, savedName: "",
            status: new DeviceStatus("", null, null, null, null, null, null)));

        Assert.Equal(("Dee's iPhone", "iPhone · 00008110…"), (live.Title, live.Detail));
        Assert.Equal(("Dee's iPhone", "iPhone · 00008110…"), (saved.Title, saved.Detail));
        Assert.Equal(("iPhone", "00008110…"), (unknown.Title, unknown.Detail));
        Assert.Equal("iPhone", emptyNames.Title);
    }

    [Fact]
    public void Title_NamesTheKind_ForAnIPad()
    {
        Assert.Equal(("iPad", "00008027…"), Pair(PhoneRowModel.From(Entry(IPad, PhoneState.RemoteOnlyLater, active: false))));
        static (string, string) Pair(PhoneRowModel m) => (m.Title, m.Detail);
    }

    [Fact]
    public void Android_TheSerialIsTheId_TheModelNamesItUntilThePhoneDoes()
    {
        var noModel = new PhoneDevice("adb:R58M123", PhoneKind.Android, "R58M123", "token.android.R58M123",
            WatchTransport.Adb, (_, _) => throw new InvalidOperationException());
        Assert.Equal(("Pixel 8", "Android phone · R58M123"), Pair(PhoneRowModel.From(Entry(Android, PhoneState.NotPaired))));
        Assert.Equal(("Dee's Pixel", "Android phone · R58M123"), Pair(PhoneRowModel.From(Entry(Android, PhoneState.Paired, active: false, hasPairing: true, savedName: "Dee's Pixel"))));
        Assert.Equal(("Android phone", "R58M123"), Pair(PhoneRowModel.From(Entry(noModel, PhoneState.NotPaired))));
        static (string, string) Pair(PhoneRowModel m) => (m.Title, m.Detail);
    }

    [Fact]
    public void ActivityLine_OnlyForTheActivePairedPhone()
    {
        var paired = PhoneRowModel.From(Entry(IPhone, PhoneState.Paired, hasPairing: true, connections: 3, rx: 1_200_000, tx: 34_000));
        var one = PhoneRowModel.From(Entry(IPhone, PhoneState.Paired, hasPairing: true, connections: 1));
        Assert.Equal("3 connections · ↓ 1.2 MB ↑ 34 KB", paired.ActivityLine);
        Assert.True(paired.ShowActivity);
        Assert.Equal("1 connection · ↓ 0 B ↑ 0 B", one.ActivityLine);
        Assert.Equal("", PhoneRowModel.From(Entry(IPhone, PhoneState.Paired, active: false, hasPairing: true, connections: 3)).ActivityLine);
        Assert.Equal("", PhoneRowModel.From(Entry(IPhone, PhoneState.Connecting, connections: 3)).ActivityLine);
        Assert.False(PhoneRowModel.From(Entry(IPhone, PhoneState.Connecting)).ShowActivity);
    }

    [Fact]
    public void Message_ShownInAnyState_IncludingTheDropReasonWhileConnecting()
    {
        var reason = PhoneRowModel.From(Entry(IPhone, PhoneState.Connecting,
            message: "Passthrough isn't running on the iPhone. Start it there, then connect."));
        Assert.Equal("Passthrough isn't running on the iPhone. Start it there, then connect.", reason.Message);
        Assert.True(reason.ShowMessage);
        var none = PhoneRowModel.From(Entry(IPhone, PhoneState.Connecting));
        Assert.Equal("", none.Message);
        Assert.False(none.ShowMessage);
    }

    [Theory]
    // state, active, hasPairing → ShowPair, CanPair
    [InlineData(PhoneState.NotPaired, true, false, true, true)]
    [InlineData(PhoneState.Pairing, true, false, true, false)]
    [InlineData(PhoneState.Connecting, true, false, true, true)]   // A12: an unpaired phone's channel still opening
    [InlineData(PhoneState.Connecting, true, true, false, false)]  // a paired phone reconnecting: its welcome will prove it
    [InlineData(PhoneState.Paired, true, true, false, false)]
    [InlineData(PhoneState.Failed, true, false, false, false)]
    [InlineData(PhoneState.NotPaired, false, false, false, true)]  // another phone: no box
    public void CodeBox(PhoneState state, bool active, bool hasPairing, bool showPair, bool canPair)
    {
        var m = PhoneRowModel.From(Entry(IPhone, state, active, hasPairing));
        Assert.Equal((showPair, canPair), (m.ShowPair, m.CanPair));
    }

    [Theory]
    // state, active, hasPairing → retry, use, forget
    [InlineData(PhoneState.Failed, true, true, true, false, true)]
    [InlineData(PhoneState.Failed, true, false, true, false, false)]
    [InlineData(PhoneState.Connecting, true, true, false, false, true)]
    [InlineData(PhoneState.Paired, false, true, false, true, true)]
    [InlineData(PhoneState.NotPaired, false, false, false, true, false)]
    [InlineData(PhoneState.RemoteOnlyLater, false, false, false, false, false)]
    public void Buttons(PhoneState state, bool active, bool hasPairing, bool retry, bool use, bool forget)
    {
        var m = PhoneRowModel.From(Entry(IPhone, state, active, hasPairing));
        Assert.Equal((retry, use, forget), (m.ShowRetry, m.ShowUse, m.ShowForget));
    }

    [Fact]
    public void StatusLine_ComesFromTheStatus()
    {
        var m = PhoneRowModel.From(Entry(IPhone, PhoneState.Paired, hasPairing: true,
            status: new DeviceStatus("x", "5G", "Carrier", 0.85, null, null, null)));
        Assert.Equal("Carrier · 5G · 85%", m.StatusLine);
        Assert.True(m.ShowStatus);
        Assert.False(PhoneRowModel.From(Entry(IPhone, PhoneState.Paired)).ShowStatus);
    }
}
