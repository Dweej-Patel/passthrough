using System.Net.Sockets;

namespace Passthrough.Core.Transport;

/// <summary>
/// Watches usbmuxd (Apple Devices) for iPhones and iPads on the cable. When nothing answers on its port it reports
/// <see cref="WatchState.NotInstalled"/>; when usbmuxd answers but fails (refuses, falls silent, drops the listen) it
/// reports <see cref="WatchState.Unavailable"/>. Either way it retries every five seconds until stopped. Events fire on
/// background threads.
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
            var refused = false;
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
                ReportError(new EndOfStreamException("usbmuxd ended the device watch"));
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (SocketException e) when (!listening)
            {
                refused = true; // nothing answers on its port: Apple Devices is not installed, or not running
                ReportError(e);
            }
            catch (Exception e)
            {
                // Falls through to the retry below: a daemon that answers but fails is handled like a dropped listen.
                ReportError(e);
            }

            if (devices.Count > 0) Publish([]);
            SetStatus(refused
                ? new WatchStatus(WatchState.NotInstalled, NotInstalledHint)
                : new WatchStatus(WatchState.Unavailable));
            if (!await DelayAsync(RetryDelay, ct)) return;
        }
    }
}
