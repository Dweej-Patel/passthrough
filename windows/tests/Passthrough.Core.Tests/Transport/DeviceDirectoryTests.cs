using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Transport;

public class DeviceDirectoryTests
{
    private sealed class FakeWatcher(WatchTransport transport) : IDeviceWatcher
    {
        public WatchTransport Transport { get; } = transport;
        public WatchStatus Status { get; set; } = new(WatchState.Idle);
        public event Action<IReadOnlyList<PhoneDevice>>? DevicesChanged;
        public event Action<WatchStatus>? StatusChanged;
        public bool Started;
        public void Start() => Started = true;
        public Task StopAsync() { Report([]); return Task.CompletedTask; }
        public void Report(params PhoneDevice[] devices) => DevicesChanged?.Invoke(devices);
        public void SetStatus(WatchStatus s) { Status = s; StatusChanged?.Invoke(s); }
    }

    private static PhoneDevice Phone(string id, WatchTransport t = WatchTransport.UsbMux) =>
        new(id, PhoneKind.IPhone, id, "token.iphone." + id, t, (_, _) => throw new NotSupportedException());

    [Fact]
    public void DeviceDirectory_AttachOrderAndDetach()
    {
        var usb = new FakeWatcher(WatchTransport.UsbMux);
        var adb = new FakeWatcher(WatchTransport.Adb);
        var directory = new DeviceDirectory([usb, adb]);
        var changes = new List<DeviceChange>();
        directory.Changed += changes.Add;
        var a = Phone("A");
        var b = Phone("B", WatchTransport.Adb);

        usb.Report(a);
        adb.Report(b);
        usb.Report();

        Assert.Equal([b], directory.Devices);
        Assert.Equal(
            new DeviceChange[] { new DeviceChange.Attached(a), new DeviceChange.Attached(b), new DeviceChange.Detached(a) },
            changes);
    }

    [Fact]
    public void DeviceDirectory_OneWatcherDown_OtherStillReports()
    {
        var usb = new FakeWatcher(WatchTransport.UsbMux);
        var adb = new FakeWatcher(WatchTransport.Adb);
        var directory = new DeviceDirectory([usb, adb]);

        usb.SetStatus(new WatchStatus(WatchState.NotInstalled, "Install Apple Devices from the Microsoft Store to use an iPhone."));
        var phone = Phone("R58M123", WatchTransport.Adb);
        adb.Report(phone);

        Assert.Equal([phone], directory.Devices);
        Assert.Equal(WatchState.NotInstalled, directory.Watcher(WatchTransport.UsbMux)!.Status.State);
        Assert.Same(adb, directory.Watcher(WatchTransport.Adb));
        Assert.Null(directory.Watcher(WatchTransport.Wireless));
        Assert.Equal(2, directory.Watchers.Count);
    }

    [Fact]
    public void DeviceDirectory_ReplugReadsAsFreshArrival()
    {
        var usb = new FakeWatcher(WatchTransport.UsbMux);
        var directory = new DeviceDirectory([usb]);
        var changes = new List<DeviceChange>();
        directory.Changed += changes.Add;

        usb.Report(Phone("usbmux:3"));
        usb.Report(Phone("usbmux:4"));

        Assert.Equal(
            ["Attached:usbmux:3", "Detached:usbmux:3", "Attached:usbmux:4"],
            changes.Select(c => c switch { DeviceChange.Attached x => "Attached:" + x.Device.Id, DeviceChange.Detached x => "Detached:" + x.Device.Id, _ => "?" }));
    }

    [Fact]
    public async Task DeviceDirectory_StartAndStopReachEveryWatcher()
    {
        var usb = new FakeWatcher(WatchTransport.UsbMux);
        var directory = new DeviceDirectory([usb]);
        directory.Start();
        usb.Report(Phone("A"));

        await directory.StopAsync();

        Assert.True(usb.Started);
        Assert.Empty(directory.Devices);
    }

    [Fact]
    public void PhoneDevice_SlotSafe()
    {
        var d = PhoneDevice.FromAdb(new AdbDevice("a/b c", "device", null, true), new AdbClient(_ => throw new NotSupportedException()));

        Assert.Equal("token.android.abc", d.PairingSlot);
        Assert.Equal("adb:a/b c", d.Id);
        Assert.Equal("a/b c", d.Label);
    }

    [Fact]
    public void PhoneDevice_UsbMuxIdsAndLabels_EqualityById()
    {
        var c = new UsbMuxClient(_ => throw new NotSupportedException());
        var d = PhoneDevice.FromUsbMux(new UsbMuxDevice(3, "00008110-ABCDEF", 0x12A8, "USB"), c);

        Assert.Equal("usbmux:3", d.Id);
        Assert.Equal("00008110…", d.Label);
        Assert.Equal(d, PhoneDevice.FromUsbMux(new UsbMuxDevice(3, "other", 0x12AB, "USB"), c));
        Assert.Equal("iPhone", PhoneKind.IPhone.Label());
        Assert.Equal("Android phone", PhoneKind.Android.Label());
        Assert.Equal("iPad", PhoneKind.IPad.Label());
    }
}
