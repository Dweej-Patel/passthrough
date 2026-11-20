using System.Buffers.Binary;
using System.Runtime.CompilerServices;

namespace Passthrough.Core.Transport;

/// <summary>Speaks the usbmuxd plist protocol so the PC can open TCP streams to ports on a USB-attached iPhone or iPad.</summary>
/// <param name="connect">Opens a connection to usbmuxd.</param>
/// <param name="connectTimeout">
/// How long usbmuxd may take to accept a connection, to answer a request, and to finish a packet once it has begun
/// (10 s by default). A <see cref="ListenAsync"/> subscription may sit idle between packets for any length of time.
/// </param>
public sealed class UsbMuxClient(StreamConnector connect, TimeSpan? connectTimeout = null)
{
    private readonly TimeSpan _connectTimeout = connectTimeout ?? TimeSpan.FromSeconds(10);

    private const int HeaderSize = 16;
    private const int MaxPacket = 1 << 20;

    /// <summary>
    /// Subscribes to attach and detach events. Throws <see cref="TimeoutException"/> when usbmuxd does not accept the
    /// subscription in time or stops partway through a packet, and <see cref="UsbMuxException"/> when it refuses it.
    /// </summary>
    public async IAsyncEnumerable<UsbMuxEvent> ListenAsync([EnumeratorCancellation] CancellationToken ct, Action? onListening = null)
    {
        var usbDevices = new HashSet<int>();
        var stream = await WithDeadlineAsync(c => connect(c), ct);
        try
        {
            await WithDeadlineAsync(async c => { await SendAsync(stream, new Dictionary<string, object> { ["MessageType"] = "Listen" }, tag: 1, c); return true; }, ct);
            var answered = false;
            while (true)
            {
                // The answer to Listen is due in time; after it, the subscription may wait as long as no phone comes or goes.
                var message = await ReadMessageAsync(stream, waitIdle: answered, ct);
                if (message is null) yield break;
                answered = true;

                switch (message.GetValueOrDefault("MessageType") as string)
                {
                    case "Result":
                        CheckResult(message);
                        onListening?.Invoke();
                        break;
                    case "Attached" when message.GetValueOrDefault("DeviceID") is long id
                                         && message.GetValueOrDefault("Properties") is Dictionary<string, object> props:
                        var device = new UsbMuxDevice(
                            (int)id,
                            props.GetValueOrDefault("SerialNumber") as string ?? "",
                            props.GetValueOrDefault("ProductID") is long pid ? (int)pid : 0,
                            props.GetValueOrDefault("ConnectionType") as string ?? "");
                        // USB only: network (Wi-Fi) devices are never reported.
                        if (!device.IsUsb) break;
                        usbDevices.Add(device.DeviceId);
                        yield return new UsbMuxEvent.Attached(device);
                        break;
                    case "Detached" when message.GetValueOrDefault("DeviceID") is long detachedId:
                        if (usbDevices.Remove((int)detachedId))
                            yield return new UsbMuxEvent.Detached((int)detachedId);
                        break;
                }
            }
        }
        finally
        {
            await stream.DisposeAsync();
        }
    }

    /// <summary>Opens a TCP stream to <paramref name="port"/> on the device. The returned stream is the raw connection; the caller owns it.</summary>
    public Task<Stream> ConnectAsync(int deviceId, int port, CancellationToken ct) =>
        WithDeadlineAsync(c => ConnectCoreAsync(deviceId, port, c), ct);

    /// <summary>Runs <paramref name="op"/> with <see cref="_connectTimeout"/> on top of <paramref name="ct"/>; running out of time is a <see cref="TimeoutException"/>.</summary>
    private async Task<T> WithDeadlineAsync<T>(Func<CancellationToken, Task<T>> op, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(_connectTimeout);
        try
        {
            return await op(timeout.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new TimeoutException("usbmuxd did not answer in time");
        }
    }

    private async Task<Stream> ConnectCoreAsync(int deviceId, int port, CancellationToken ct)
    {
        var stream = await connect(ct);
        try
        {
            // usbmuxd wants the port in network byte order.
            var swapped = ((port & 0xFF) << 8) | ((port >> 8) & 0xFF);
            await SendAsync(stream, new Dictionary<string, object>
            {
                ["MessageType"] = "Connect",
                ["DeviceID"] = (long)deviceId,
                ["PortNumber"] = (long)swapped,
            }, tag: 2, ct);

            var reply = await ReadMessageAsync(stream, waitIdle: false, ct) ?? throw new EndOfStreamException("usbmuxd closed the connection");
            CheckResult(reply);
            return stream;
        }
        catch
        {
            await stream.DisposeAsync();
            throw;
        }
    }

    private static void CheckResult(Dictionary<string, object> message)
    {
        var number = message.GetValueOrDefault("Number") is long n ? (int)n : -1;
        if (number != 0) throw new UsbMuxException(number);
    }

    private static async Task SendAsync(Stream stream, Dictionary<string, object> message, uint tag, CancellationToken ct)
    {
        var plist = new Dictionary<string, object>(message)
        {
            ["ClientVersionString"] = "Passthrough",
            ["ProgName"] = "Passthrough",
            ["kLibUSBMuxVersion"] = 3L,
        };
        var body = Plist.Encode(plist);
        var packet = new byte[HeaderSize + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(0), (uint)packet.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(4), 1); // version
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(8), 8); // plist message
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(12), tag);
        body.CopyTo(packet.AsSpan(HeaderSize));
        await stream.WriteAsync(packet, ct);
        await stream.FlushAsync(ct);
    }

    /// <summary>
    /// Reads one packet; null when the peer closed cleanly before a new packet began. A packet once begun must finish
    /// in time; with <paramref name="waitIdle"/> false, so must its first byte.
    /// </summary>
    private async Task<Dictionary<string, object>?> ReadMessageAsync(Stream stream, bool waitIdle, CancellationToken ct)
    {
        var header = new byte[HeaderSize];
        var first = waitIdle
            ? await stream.ReadAsync(header.AsMemory(0, 1), ct)
            : await WithDeadlineAsync(c => stream.ReadAsync(header.AsMemory(0, 1), c).AsTask(), ct);
        if (first == 0) return null;
        var body = await WithDeadlineAsync(async c =>
        {
            await stream.ReadExactlyAsync(header.AsMemory(1), c);
            var length = BinaryPrimitives.ReadUInt32LittleEndian(header);
            if (length < HeaderSize || length >= MaxPacket) throw new InvalidDataException("usbmuxd sent an unexpected reply");
            var bytes = new byte[length - HeaderSize];
            await stream.ReadExactlyAsync(bytes, c);
            return bytes;
        }, ct);
        try
        {
            return Plist.Decode(body);
        }
        catch (Exception e) when (e is FormatException or OverflowException or System.Xml.XmlException)
        {
            throw new InvalidDataException("usbmuxd sent an unexpected reply", e);
        }
    }
}
