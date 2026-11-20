using System.Buffers.Binary;
using System.Runtime.CompilerServices;

namespace Passthrough.Core.Transport;

/// <summary>Speaks the usbmuxd plist protocol so the PC can open TCP streams to ports on a USB-attached iPhone or iPad.</summary>
public sealed class UsbMuxClient(StreamConnector connect, TimeSpan? connectTimeout = null)
{
    private readonly TimeSpan _connectTimeout = connectTimeout ?? TimeSpan.FromSeconds(10);

    private const int HeaderSize = 16;
    private const int MaxPacket = 1 << 20;

    public async IAsyncEnumerable<UsbMuxEvent> ListenAsync([EnumeratorCancellation] CancellationToken ct, Action? onListening = null)
    {
        var usbDevices = new HashSet<int>();
        var stream = await connect(ct);
        try
        {
            await SendAsync(stream, new Dictionary<string, object> { ["MessageType"] = "Listen" }, tag: 1, ct);
            while (true)
            {
                var message = await ReadMessageAsync(stream, ct);
                if (message is null) yield break;

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
    public async Task<Stream> ConnectAsync(int deviceId, int port, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(_connectTimeout);
        try
        {
            return await ConnectCoreAsync(deviceId, port, timeout.Token);
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

            var reply = await ReadMessageAsync(stream, ct) ?? throw new EndOfStreamException("usbmuxd closed the connection");
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

    /// <summary>Reads one packet; null when the peer closed cleanly before a new packet began.</summary>
    private static async Task<Dictionary<string, object>?> ReadMessageAsync(Stream stream, CancellationToken ct)
    {
        var header = new byte[HeaderSize];
        var first = await stream.ReadAsync(header.AsMemory(0, 1), ct);
        if (first == 0) return null;
        await stream.ReadExactlyAsync(header.AsMemory(1), ct);

        var length = BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (length < HeaderSize || length >= MaxPacket) throw new InvalidDataException("usbmuxd sent an unexpected reply");
        var body = new byte[length - HeaderSize];
        await stream.ReadExactlyAsync(body, ct);
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
