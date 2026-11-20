namespace Passthrough.Core.Transport;

/// <summary>
/// Watches usbmuxd (Apple Devices) for iPhones and iPads on the cable. When it cannot connect it reports
/// <see cref="WatchState.NotInstalled"/> and retries every five seconds until stopped. Events fire on background threads.
/// </summary>
public sealed class UsbMuxWatcher(UsbMuxClient client, TimeProvider time) : WatcherBase(WatchTransport.UsbMux, time)
{
    public const string NotInstalledHint = "Install Apple Devices from the Microsoft Store to use an iPhone.";

    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(5);

    protected override async Task RunAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var listening = false;
            var devices = new List<PhoneDevice>();
            if (Status.State == WatchState.Idle) SetStatus(new WatchStatus(WatchState.Starting));
            try
            {
                await foreach (var e in client.ListenAsync(ct, () =>
                {
                    listening = true;
                    SetStatus(new WatchStatus(WatchState.Watching));
                }))
                {
                    switch (e)
                    {
                        case UsbMuxEvent.Attached a when devices.All(d => d.Id != $"usbmux:{a.Device.DeviceId}"):
                            devices.Add(PhoneDevice.FromUsbMux(a.Device, client));
                            Publish([.. devices]);
                            break;
                        case UsbMuxEvent.Detached d:
                            if (devices.RemoveAll(x => x.Id == $"usbmux:{d.DeviceId}") > 0) Publish([.. devices]);
                            break;
                    }
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception)
            {
                // Falls through to the retry below: a failed connect or a dropped listen is handled the same way.
            }

            if (devices.Count > 0) Publish([]);
            SetStatus(listening
                ? new WatchStatus(WatchState.Unavailable)
                : new WatchStatus(WatchState.NotInstalled, NotInstalledHint));
            if (!await DelayAsync(RetryDelay, ct)) return;
        }
    }
}
