using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text;

namespace Passthrough.Core.Transport;

/// <summary>Speaks the adb host protocol to the local adb server so the PC can open TCP streams to ports on a USB-attached Android phone.</summary>
public sealed class AdbClient(StreamConnector connect, TimeSpan? connectTimeout = null)
{
    private readonly TimeSpan _connectTimeout = connectTimeout ?? TimeSpan.FromSeconds(10);

    private const int MaxBlock = 1 << 20;

    /// <summary>Yields the USB-attached device list (Wi-Fi and emulator entries removed) each time the adb server reports.</summary>
    public async IAsyncEnumerable<IReadOnlyList<AdbDevice>> TrackDevicesAsync([EnumeratorCancellation] CancellationToken ct)
    {
        var stream = await connect(ct);
        try
        {
            await SendAsync(stream, "host:track-devices-l", ct);
            await ReadStatusAsync(stream, ct);
            while (true)
            {
                var text = await ReadLengthPrefixedAsync(stream, allowCleanEof: true, ct);
                if (text is null) yield break;
                yield return ParseDevices(text).Where(d => d.IsUsb).ToList();
            }
        }
        finally
        {
            await stream.DisposeAsync();
        }
    }

    /// <summary>Opens a TCP stream to <paramref name="port"/> on the phone's loopback, through adbd. The returned stream is the raw connection; the caller owns it.</summary>
    public async Task<Stream> ConnectAsync(string serial, int port, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(_connectTimeout);
        try
        {
            return await ConnectCoreAsync(serial, port, timeout.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new TimeoutException("adb did not answer in time");
        }
    }

    /// <summary>Starts the adb server when nothing answers on its port: runs <c>adb start-server</c> once, then retries.</summary>
    public static async Task EnsureServerAsync(AdbClient client, string? adbPath, IProcessRunner runner, CancellationToken ct)
    {
        try
        {
            await client.ProbeAsync(ct);
            return;
        }
        catch (SocketException) when (adbPath is null)
        {
            throw; // adb is not installed; nothing to start.
        }
        catch (SocketException)
        {
        }
        await runner.RunAsync(adbPath!, "start-server", ct);
        await client.ProbeAsync(ct);
    }

    private async Task ProbeAsync(CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(_connectTimeout);
        await using var stream = await connect(timeout.Token);
    }

    private async Task<Stream> ConnectCoreAsync(string serial, int port, CancellationToken ct)
    {
        var stream = await connect(ct);
        try
        {
            await SendAsync(stream, $"host:transport:{serial}", ct);
            await ReadStatusAsync(stream, ct);
            await SendAsync(stream, $"tcp:{port}", ct);
            await ReadStatusAsync(stream, ct);
            return stream;
        }
        catch
        {
            await stream.DisposeAsync();
            throw;
        }
    }

    /// <summary>Parses <c>host:track-devices-l</c> output. States may be two words ("no permissions"); key:value pairs follow.</summary>
    internal static List<AdbDevice> ParseDevices(string text)
    {
        var devices = new List<AdbDevice>();
        foreach (var line in text.Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries))
        {
            var fields = line.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2) continue;
            var stateWords = new List<string>();
            var props = new Dictionary<string, string>();
            foreach (var field in fields.Skip(1))
            {
                var colon = field.IndexOf(':');
                if (colon >= 0) props[field[..colon]] = field[(colon + 1)..];
                else if (props.Count == 0) stateWords.Add(field);
            }
            devices.Add(new AdbDevice(
                fields[0],
                string.Join(' ', stateWords),
                props.GetValueOrDefault("model")?.Replace('_', ' '),
                props.ContainsKey("usb")));
        }
        return devices;
    }

    private static async Task SendAsync(Stream stream, string payload, CancellationToken ct)
    {
        var body = Encoding.UTF8.GetBytes(payload);
        var packet = Encoding.ASCII.GetBytes(body.Length.ToString("x4")).Concat(body).ToArray();
        await stream.WriteAsync(packet, ct);
        await stream.FlushAsync(ct);
    }

    private static async Task ReadStatusAsync(Stream stream, CancellationToken ct)
    {
        var status = Encoding.ASCII.GetString(await ReadExactAsync(stream, 4, ct));
        switch (status)
        {
            case "OKAY":
                return;
            case "FAIL":
                throw new AdbException(await ReadLengthPrefixedAsync(stream, allowCleanEof: false, ct) ?? "unknown error");
            default:
                throw new InvalidDataException("adb sent an unexpected reply");
        }
    }

    /// <summary>Reads a hex length and that many bytes; null only when allowed and the peer closed before a new block began.</summary>
    private static async Task<string?> ReadLengthPrefixedAsync(Stream stream, bool allowCleanEof, CancellationToken ct)
    {
        var hex = new byte[4];
        var first = await stream.ReadAsync(hex.AsMemory(0, 1), ct);
        if (first == 0)
        {
            if (allowCleanEof) return null;
            throw new EndOfStreamException("adb closed the connection");
        }
        await stream.ReadExactlyAsync(hex.AsMemory(1), ct);
        if (!int.TryParse(Encoding.ASCII.GetString(hex), System.Globalization.NumberStyles.AllowHexSpecifier, null, out var length)
            || length >= MaxBlock)
            throw new InvalidDataException("adb sent an unexpected reply");
        if (length == 0) return "";
        return Encoding.UTF8.GetString(await ReadExactAsync(stream, length, ct));
    }

    private static async Task<byte[]> ReadExactAsync(Stream stream, int count, CancellationToken ct)
    {
        var buffer = new byte[count];
        await stream.ReadExactlyAsync(buffer, ct);
        return buffer;
    }
}
