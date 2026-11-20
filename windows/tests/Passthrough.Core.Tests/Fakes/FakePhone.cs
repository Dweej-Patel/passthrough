using System.Net;
using System.Net.Sockets;
using Passthrough.Core.Protocol;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Tests.Fakes;

/// <summary>
/// The phone side of the control channel (protocol/README.md §Control channel, §Authentication, §Pairing)
/// on a loopback port, scripted per test through its init properties. Records every envelope it receives
/// and a transcript of what it received and sent, in order.
/// </summary>
public sealed class FakePhone : IAsyncDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly Task _accepting;
    private readonly CancellationTokenSource _stop = new();
    private readonly List<Task> _handlers = [];
    private readonly List<ControlEnvelope> _received = [];
    private readonly List<string> _transcript = [];
    private volatile bool _closing;
    private int _wrongGuesses;

    public FakePhone()
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
                            try { await ServeAsync(client.GetStream()); }
                            catch (IOException) { } // the PC hung up; any other failure (e.g. an assertion) is rethrown by DisposeAsync
                        }
                    });
                    lock (_handlers) _handlers.Add(task);
                }
            }
            catch (Exception) when (_closing) { }
        });
    }

    /// <summary>The pairing token this phone holds (it keeps K = SHA-256(token)); null: not paired with this PC.</summary>
    public string? Token { get; init; }

    /// <summary>The six-digit code the phone is showing.</summary>
    public string Code { get; init; } = "042917";

    /// <summary>The token a successful code pairing issues.</summary>
    public string IssuedToken { get; init; } = "issued-token-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    public string DeviceName { get; init; } = "Test Phone";

    public int ProtocolVersion { get; init; } = ProtocolConstants.Version;

    /// <summary>Answer a <c>hello</c> of another version with <c>error unsupported_version</c> (true) or a <c>welcome</c> anyway (false).</summary>
    public bool RejectsOtherVersions { get; init; } = true;

    /// <summary>Send <c>paired: true</c> with a proof that is not the phone proof.</summary>
    public bool BadProof { get; init; }

    /// <summary>After the first <c>status</c>, answer nothing (no <c>pong</c>) but keep the connection open.</summary>
    public bool SilentAfterStatus { get; init; }

    /// <summary>After the first <c>status</c>, answer each <c>ping</c> with a message of an unknown type instead of <c>pong</c>.</summary>
    public bool ChattersInsteadOfPong { get; init; }

    /// <summary>After the first <c>status</c>, send <c>goodbye</c> and close.</summary>
    public bool GoodbyeAfterStatus { get; init; }

    /// <summary>
    /// Right after <c>welcome</c>, send a <c>paired</c> the PC never asked for, carrying this token, then close: by
    /// the time the PC reports the close, it has read the planted <c>paired</c>.
    /// </summary>
    public string? UnsolicitedPairedToken { get; init; }

    /// <summary>Right after <c>welcome</c>, send an <c>error</c> with this reason the PC never asked for, then close.</summary>
    public string? ErrorAfterWelcome { get; init; }

    /// <summary>Answer every <c>auth</c> with <c>error not_authenticated</c> and close, even a correct one.</summary>
    public bool RejectsAuth { get; init; }

    /// <summary>Answer a right code with a <c>paired</c> that carries no token.</summary>
    public bool PairedWithoutToken { get; init; }

    /// <summary>Instead of a <c>welcome</c>, write these bytes after <c>hello</c> and hold the connection open.</summary>
    public byte[]? GarbageAfterHello { get; init; }

    /// <summary>Close right after <see cref="GarbageAfterHello"/> instead of holding the connection open.</summary>
    public bool CloseAfterGarbage { get; init; }

    /// <summary>
    /// After answering a wrong code with <c>bad_code</c>, also send a <c>paired</c> carrying this token, then close:
    /// by the time the PC reports the close, it has read the planted <c>paired</c>.
    /// </summary>
    public string? PairedAfterErrorToken { get; init; }

    /// <summary>Wrong guesses against the current code from earlier connections (the tenth withdraws it).</summary>
    public int PriorWrongGuesses { get; init; }

    /// <summary>When set, <c>welcome</c> waits for this task.</summary>
    public Task? WelcomeGate { get; init; }

    /// <summary>The nonce the phone sent in its last <c>welcome</c>.</summary>
    public byte[]? PhoneNonce { get; private set; }

    public Func<CancellationToken, Task<Stream>> Open => ct => ByteStreamConnector.Tcp("127.0.0.1", Port)(ct);

    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public IReadOnlyList<ControlEnvelope> Received
    {
        get { lock (_received) return [.. _received]; }
    }

    /// <summary>"recv hello", "sent welcome", ... in the order they happened.</summary>
    public IReadOnlyList<string> Transcript
    {
        get { lock (_received) return [.. _transcript]; }
    }

    /// <summary>Waits for every connection so far to end (the PC closed it, or the script did), rethrowing any handler failure.</summary>
    public async Task WaitClosedAsync()
    {
        Task[] handlers;
        lock (_handlers) handlers = [.. _handlers];
        await Task.WhenAll(handlers).WaitAsync(TimeSpan.FromSeconds(10));
    }

    private async Task ServeAsync(Stream s)
    {
        var lines = new LineReader(s);
        var hello = await ReceiveAsync(lines);
        if (hello is null) return;

        if (GarbageAfterHello is not null)
        {
            await s.WriteAsync(GarbageAfterHello);
            await s.FlushAsync();
            if (!CloseAfterGarbage) await HoldOpenAsync(s);
            return;
        }

        if (hello.ProtocolVersion != ProtocolVersion && RejectsOtherVersions)
        {
            await SendAsync(s, new ControlEnvelope(ControlEnvelope.Error)
            {
                Reason = PairingFailure.UnsupportedVersion.ToWire(),
                ProtocolVersion = ProtocolVersion,
            });
            return;
        }

        if (WelcomeGate is not null) await WelcomeGate.WaitAsync(TimeSpan.FromSeconds(10));

        var macNonce = Convert.FromBase64String(hello.Nonce!);
        var phoneNonce = ControlAuth.Nonce();
        PhoneNonce = phoneNonce;
        var key = Token is null ? null : ControlAuth.Key(Token);
        var welcome = new ControlEnvelope(ControlEnvelope.Welcome)
        {
            ProtocolVersion = ProtocolVersion,
            PairedFlag = key is not null,
            Nonce = Convert.ToBase64String(phoneNonce),
        };
        if (key is not null)
        {
            welcome.Proof = Convert.ToBase64String(BadProof
                ? ControlAuth.Nonce()
                : ControlAuth.PhoneProof(key, hello.ClientID!, macNonce, phoneNonce));
        }
        await SendAsync(s, welcome);

        if (UnsolicitedPairedToken is not null)
        {
            await SendAsync(s, new ControlEnvelope(ControlEnvelope.Paired) { Token = UnsolicitedPairedToken });
            return;
        }

        if (ErrorAfterWelcome is not null)
        {
            await SendAsync(s, new ControlEnvelope(ControlEnvelope.Error) { Reason = ErrorAfterWelcome });
            return;
        }

        var silent = false;
        var chatter = false;
        var wrongHere = 0;
        while (await ReceiveAsync(lines) is { } m)
        {
            switch (m.T)
            {
                case ControlEnvelope.Auth:
                    var expected = key is null ? null : ControlAuth.MacProof(key, hello.ClientID!, macNonce, phoneNonce);
                    if (RejectsAuth || expected is null || m.Proof != Convert.ToBase64String(expected))
                    {
                        await SendAsync(s, new ControlEnvelope(ControlEnvelope.Error) { Reason = PairingFailure.NotAuthenticated.ToWire() });
                        return;
                    }
                    if (!await SendStatusAsync(s)) return;
                    silent = SilentAfterStatus;
                    chatter = ChattersInsteadOfPong;
                    break;
                case ControlEnvelope.Pair:
                    if (m.Code == Code && m.ClientID == hello.ClientID)
                    {
                        await SendAsync(s, new ControlEnvelope(ControlEnvelope.Paired)
                        {
                            Token = PairedWithoutToken ? null : IssuedToken,
                            SocksPort = ProtocolConstants.SocksPort,
                            DeviceName = DeviceName,
                        });
                        if (!await SendStatusAsync(s)) return;
                        silent = SilentAfterStatus;
                        break;
                    }
                    wrongHere++;
                    var wrongTotal = PriorWrongGuesses + Interlocked.Increment(ref _wrongGuesses);
                    if (wrongTotal >= 10)
                    {
                        await SendAsync(s, new ControlEnvelope(ControlEnvelope.Error) { Reason = PairingFailure.CodeWithdrawn.ToWire() });
                    }
                    else if (wrongHere >= 3)
                    {
                        await SendAsync(s, new ControlEnvelope(ControlEnvelope.Error) { Reason = PairingFailure.Locked.ToWire() });
                        return;
                    }
                    else
                    {
                        await SendAsync(s, new ControlEnvelope(ControlEnvelope.Error) { Reason = PairingFailure.BadCode.ToWire() });
                        if (PairedAfterErrorToken is not null)
                        {
                            await SendAsync(s, new ControlEnvelope(ControlEnvelope.Paired) { Token = PairedAfterErrorToken });
                            return;
                        }
                    }
                    break;
                case ControlEnvelope.Ping:
                    if (chatter) await SendAsync(s, new ControlEnvelope("chatter"));
                    else if (!silent) await SendAsync(s, new ControlEnvelope(ControlEnvelope.Pong));
                    break;
            }
        }
    }

    /// <summary>Sends a status; false when the script ends the connection after it.</summary>
    private async Task<bool> SendStatusAsync(Stream s)
    {
        await SendAsync(s, new ControlEnvelope(ControlEnvelope.Status)
        {
            DeviceName = DeviceName,
            Radio = "5G",
            Carrier = "Carrier",
            Battery = 0.5,
            Hosting = "foreground",
            Ipv6 = true,
            ActiveConnections = 3,
            RxBytes = 1000,
            TxBytes = 2000,
        });
        if (!GoodbyeAfterStatus) return true;
        await SendAsync(s, new ControlEnvelope(ControlEnvelope.Goodbye));
        return false;
    }

    private async Task<ControlEnvelope?> ReceiveAsync(LineReader lines)
    {
        var line = await lines.ReadLineAsync();
        if (line is null) return null;
        var m = ControlEnvelope.Decode(line);
        lock (_received)
        {
            _received.Add(m);
            _transcript.Add("recv " + m.T);
        }
        return m;
    }

    private async Task SendAsync(Stream s, ControlEnvelope m)
    {
        lock (_received) _transcript.Add("sent " + m.T);
        await s.WriteAsync(m.EncodeLine());
        await s.FlushAsync();
    }

    private static async Task HoldOpenAsync(Stream s)
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
        try
        {
            await WaitClosedAsync();
        }
        finally
        {
            await _stop.CancelAsync();
            _stop.Dispose();
        }
    }

    /// <summary>Newline-framed reads, independent of the client's own framing; returns null at EOF.</summary>
    private sealed class LineReader(Stream s)
    {
        private readonly byte[] _one = new byte[1];
        private readonly MemoryStream _line = new();

        public async Task<byte[]?> ReadLineAsync()
        {
            _line.SetLength(0);
            while (true)
            {
                if (await s.ReadAsync(_one) == 0) return null;
                if (_one[0] == (byte)'\n')
                {
                    if (_line.Length == 0) continue;
                    return _line.ToArray();
                }
                _line.WriteByte(_one[0]);
            }
        }
    }
}
