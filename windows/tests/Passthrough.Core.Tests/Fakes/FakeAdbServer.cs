using System.Net;
using System.Net.Sockets;
using System.Text;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Tests.Fakes;

/// <summary>Loopback adb server stand-in on an ephemeral port. Runs the handler once per accepted connection.</summary>
public sealed class FakeAdbServer : IAsyncDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly Task _accepting;
    private readonly CancellationTokenSource _stop = new();
    private readonly List<Task> _handlers = [];
    private volatile bool _closing;

    public FakeAdbServer(Func<Stream, Task> handler)
    {
        _listener.Start();
        _accepting = Task.Run(async () =>
        {
            try
            {
                while (true)
                {
                    var client = await _listener.AcceptTcpClientAsync(_stop.Token);
                    var task = Task.Run(async () =>
                    {
                        using (client)
                        {
                            try { await handler(client.GetStream()); }
                            catch (IOException) { } // client hung up; any other failure (e.g. an assertion) is rethrown by DisposeAsync
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

    /// <summary>Reads one smart-socket request: four hex digits of length, then the payload.</summary>
    public static async Task<string> ReadRequestAsync(Stream s)
    {
        var hex = new byte[4];
        await s.ReadExactlyAsync(hex);
        var body = new byte[Convert.ToInt32(Encoding.ASCII.GetString(hex), 16)];
        await s.ReadExactlyAsync(body);
        return Encoding.UTF8.GetString(body);
    }

    public static Task WriteAsync(Stream s, string text) => WriteBytesAsync(s, Encoding.UTF8.GetBytes(text));

    public static async Task WriteBytesAsync(Stream s, byte[] bytes)
    {
        await s.WriteAsync(bytes);
        await s.FlushAsync();
    }

    /// <summary>Writes a hex-length-prefixed block.</summary>
    public static Task WriteBlockAsync(Stream s, string text) =>
        WriteAsync(s, Encoding.UTF8.GetByteCount(text).ToString("x4") + text);

    /// <summary>Keeps the connection open until the client closes it, so a handler never outlives its test.</summary>
    public static async Task HoldOpenAsync(Stream s)
    {
        var buffer = new byte[256];
        while (await s.ReadAsync(buffer) > 0) { }
    }

    /// <summary>Stops listening, waits for every handler, and rethrows any handler failure (e.g. a failed assertion) so it fails the test.</summary>
    public async ValueTask DisposeAsync()
    {
        _closing = true;
        _listener.Stop();
        await _accepting.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        Task[] handlers;
        lock (_handlers) handlers = [.. _handlers];
        try
        {
            await Task.WhenAll(handlers).WaitAsync(TimeSpan.FromSeconds(10));
        }
        finally
        {
            await _stop.CancelAsync();
            _stop.Dispose();
        }
    }
}
