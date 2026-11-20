using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Tests.Fakes;

/// <summary>Loopback usbmuxd stand-in on an ephemeral port. Runs the handler once per accepted connection.</summary>
public sealed class FakeUsbMuxd : IAsyncDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly Task _accepting;
    private readonly CancellationTokenSource _stop = new();

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
                    _ = Task.Run(async () =>
                    {
                        using (client)
                        {
                            try { await handler(client.GetStream()); }
                            catch (Exception) when (_stop.IsCancellationRequested) { }
                        }
                    });
                }
            }
            catch (OperationCanceledException) { }
        });
    }

    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public StreamConnector Connector => ByteStreamConnector.Tcp("127.0.0.1", Port);

    public static async Task<(uint Length, uint Version, uint Type, uint Tag, Dictionary<string, object> Plist)> ReadPacketAsync(Stream s)
    {
        var header = new byte[16];
        await s.ReadExactlyAsync(header);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0));
        var version = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
        var type = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8));
        var tag = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(12));
        var body = new byte[length - 16];
        await s.ReadExactlyAsync(body);
        return (length, version, type, tag, Plist.Decode(body));
    }

    public static async Task WritePacketAsync(Stream s, uint tag, IDictionary<string, object> message)
    {
        var body = Plist.Encode(message);
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

    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync();
        _listener.Stop();
        await _accepting;
        _stop.Dispose();
    }
}
