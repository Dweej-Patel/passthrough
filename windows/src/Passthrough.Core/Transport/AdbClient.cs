using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text;

namespace Passthrough.Core.Transport;

/// <summary>Speaks the adb host protocol to the local adb server so the PC can open TCP streams to ports on a USB-attached Android phone.</summary>
/// <param name="connect">Opens a connection to the adb server.</param>
/// <param name="connectTimeout">
/// How long the server may take to accept a connection, to answer a request, and to finish a block once it has begun
/// (10 s by default). A <see cref="TrackDevicesAsync"/> subscription may sit idle between blocks for any length of time.
/// </param>
public sealed class AdbClient(StreamConnector connect, TimeSpan? connectTimeout = null)
{
    private readonly TimeSpan _connectTimeout = connectTimeout ?? TimeSpan.FromSeconds(10);

    private const int MaxBlock = 1 << 20;

    /// <summary>
    /// Yields the USB-attached device list (Wi-Fi, mDNS and emulator entries removed) each time the adb server reports.
    /// Throws <see cref="TimeoutException"/> when the server does not accept the request in time or stops partway through a block.
    /// </summary>
    public async IAsyncEnumerable<IReadOnlyList<AdbDevice>> TrackDevicesAsync([EnumeratorCancellation] CancellationToken ct)
    {
        var stream = await WithDeadlineAsync(c => connect(c), ct);
        try
        {
            await WithDeadlineAsync(async c =>
            {
                await SendAsync(stream, "host:track-devices-l", c);
                await ReadStatusAsync(stream, c);
                return true;
            }, ct);
            while (true)
            {
                var text = await ReadLengthPrefixedAsync(stream, allowCleanEof: true, waitIdle: true, ct);
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
    public Task<Stream> ConnectAsync(string serial, int port, CancellationToken ct) =>
        WithDeadlineAsync(c => ConnectCoreAsync(serial, port, c), ct);

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
            throw new TimeoutException("adb did not answer in time");
        }
    }

    /// <summary>How long <c>adb start-server</c> may run before it is killed (the Mac's limit, ADB.swift).</summary>
    public static readonly TimeSpan ServerStartTimeout = TimeSpan.FromSeconds(15);

    /// <summary>
    /// Starts the adb server when nothing answers on its port: runs <c>adb start-server</c> once, then retries. A start
    /// that runs past <see cref="ServerStartTimeout"/> on <paramref name="time"/> is cancelled (the runner kills the
    /// process) and reported as a <see cref="TimeoutException"/>.
    /// </summary>
    public static async Task EnsureServerAsync(AdbClient client, string? adbPath, IProcessRunner runner, TimeProvider time, CancellationToken ct)
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
        using (var limit = new CancellationTokenSource(ServerStartTimeout, time))
        using (var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, limit.Token))
        {
            try
            {
                await runner.RunAsync(adbPath!, "start-server", linked.Token);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new TimeoutException($"adb start-server did not finish within {ServerStartTimeout.TotalSeconds:0} seconds");
            }
        }
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
                props.ContainsKey("usb") || !IsNetworkOrEmulatorSerial(fields[0])));
        }
        return devices;
    }

    /// <summary>
    /// Whether a serial names adb over the network or an emulator: <c>host:port</c>, <c>emulator-*</c>, or an mDNS
    /// service name. Native Windows adb gives USB devices no device path, so their lines carry no <c>usb:</c>
    /// property; a line without one counts as USB unless its serial is one of these.
    /// </summary>
    internal static bool IsNetworkOrEmulatorSerial(string serial)
    {
        if (serial.StartsWith("emulator-", StringComparison.Ordinal)) return true;
        if (serial.Contains("._adb-tls-connect._tcp", StringComparison.Ordinal) || serial.Contains("._adb._tcp", StringComparison.Ordinal)) return true;
        var colon = serial.LastIndexOf(':');
        return colon >= 0 && colon < serial.Length - 1 && serial[(colon + 1)..].All(char.IsAsciiDigit);
    }

    private static async Task SendAsync(Stream stream, string payload, CancellationToken ct)
    {
        var body = Encoding.UTF8.GetBytes(payload);
        var packet = Encoding.ASCII.GetBytes(body.Length.ToString("x4")).Concat(body).ToArray();
        await stream.WriteAsync(packet, ct);
        await stream.FlushAsync(ct);
    }

    private async Task ReadStatusAsync(Stream stream, CancellationToken ct)
    {
        var status = Encoding.ASCII.GetString(await ReadExactAsync(stream, 4, ct));
        switch (status)
        {
            case "OKAY":
                return;
            case "FAIL":
                throw new AdbException(await ReadLengthPrefixedAsync(stream, allowCleanEof: false, waitIdle: false, ct) ?? "unknown error");
            default:
                throw new InvalidDataException("adb sent an unexpected reply");
        }
    }

    /// <summary>
    /// Reads a hex length and that many bytes; null only when allowed and the peer closed before a new block began. A
    /// block once begun must finish in time; with <paramref name="waitIdle"/> false, the caller bounds the wait for it.
    /// </summary>
    private async Task<string?> ReadLengthPrefixedAsync(Stream stream, bool allowCleanEof, bool waitIdle, CancellationToken ct)
    {
        var hex = new byte[4];
        var first = await stream.ReadAsync(hex.AsMemory(0, 1), ct);
        if (first == 0)
        {
            if (allowCleanEof) return null;
            throw new EndOfStreamException("adb closed the connection");
        }
        return await (waitIdle ? WithDeadlineAsync(ReadRestAsync, ct) : ReadRestAsync(ct));

        async Task<string?> ReadRestAsync(CancellationToken c)
        {
            await stream.ReadExactlyAsync(hex.AsMemory(1), c);
            if (!int.TryParse(Encoding.ASCII.GetString(hex), System.Globalization.NumberStyles.AllowHexSpecifier, null, out var length)
                || length >= MaxBlock)
                throw new InvalidDataException("adb sent an unexpected reply");
            if (length == 0) return "";
            return Encoding.UTF8.GetString(await ReadExactAsync(stream, length, c));
        }
    }

    private static async Task<byte[]> ReadExactAsync(Stream stream, int count, CancellationToken ct)
    {
        var buffer = new byte[count];
        await stream.ReadExactlyAsync(buffer, ct);
        return buffer;
    }
}
