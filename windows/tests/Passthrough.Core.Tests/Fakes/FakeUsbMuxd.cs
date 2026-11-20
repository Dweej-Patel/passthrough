using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Tests.Fakes;

/// <summary>
/// Loopback usbmuxd stand-in on an ephemeral port. Runs the handler once per accepted connection, keeps every handler
/// task, and on dispose closes the connections, waits for the handlers and rethrows any handler failure (e.g. a failed
/// assertion) so it fails the test.
/// </summary>
public sealed class FakeUsbMuxd : IAsyncDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly Task _accepting;
    private readonly CancellationTokenSource _stop = new();
    private readonly List<Task> _handlers = [];
    private readonly List<TcpClient> _clients = [];
    private volatile bool _closing;

    public FakeUsbMuxd(Func<Stream, Task> handler)
    {
        _listener.Start();
        _accepting = Task.Run(async () =>
        {
            try
            {
                while (true)
                {
                    var client = await _listener.AcceptTcpClientAsync(_stop.Token);
                    lock (_handlers) _clients.Add(client);
                    var task = Task.Run(async () =>
                    {
                        using (client)
                        {
                            try { await handler(client.GetStream()); }
                            catch (IOException) { } // the client hung up
                            catch (ObjectDisposedException) when (_closing) { } // closed by DisposeAsync
                        }
                    });
                    lock (_handlers) _handlers.Add(task);
                }
            }
            catch (Exception) when (_closing) { }
        });
    }

    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public StreamConnector Connector => ByteStreamConnector.Tcp("127.0.0.1", Port);

    /// <summary>Connections accepted so far.</summary>
    public int Accepted
    {
        get { lock (_handlers) return _clients.Count; }
    }

    public static async Task<(uint Length, uint Version, uint Type, uint Tag, Dictionary<string, object> Plist)> ReadPacketAsync(Stream s)
    {
        var (length, version, type, tag, body) = await ReadRawPacketAsync(s);
        return (length, version, type, tag, Plist.Decode(body));
    }

    /// <summary>One packet with its body left as bytes, so a test can pin exactly what the client wrote.</summary>
    public static async Task<(uint Length, uint Version, uint Type, uint Tag, byte[] Body)> ReadRawPacketAsync(Stream s)
    {
        var header = new byte[16];
        await s.ReadExactlyAsync(header);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0));
        var version = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
        var type = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8));
        var tag = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(12));
        var body = new byte[length - 16];
        await s.ReadExactlyAsync(body);
        return (length, version, type, tag, body);
    }

    public static Task WritePacketAsync(Stream s, uint tag, IDictionary<string, object> message) =>
        WriteRawPacketAsync(s, tag, Plist.Encode(message));

    /// <summary>Writes a packet around <paramref name="body"/> as given (it need not be a plist this codec would write).</summary>
    public static async Task WriteRawPacketAsync(Stream s, uint tag, byte[] body)
    {
        var packet = new byte[16 + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(0), (uint)packet.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(8), 8);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(12), tag);
        body.CopyTo(packet.AsSpan(16));
        await s.WriteAsync(packet);
        await s.FlushAsync();
    }

    public static Task WriteResultAsync(Stream s, uint tag, long number) =>
        WritePacketAsync(s, tag, new Dictionary<string, object> { ["MessageType"] = "Result", ["Number"] = number });

    /// <summary>Keeps the connection open until the client closes it (or the fake is disposed), so a handler never outlives its test.</summary>
    public static async Task HoldOpenAsync(Stream s)
    {
        var buffer = new byte[256];
        while (await s.ReadAsync(buffer) > 0) { }
    }

    /// <summary>Stops listening, closes every connection, waits for every handler, and rethrows any handler failure.</summary>
    public async ValueTask DisposeAsync()
    {
        _closing = true;
        await _stop.CancelAsync();
        _listener.Stop();
        await _accepting.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        Task[] handlers;
        lock (_handlers)
        {
            foreach (var client in _clients) client.Dispose();
            handlers = [.. _handlers];
        }
        try
        {
            await Task.WhenAll(handlers).WaitAsync(TimeSpan.FromSeconds(10));
        }
        finally
        {
            _stop.Dispose();
        }
    }
}
