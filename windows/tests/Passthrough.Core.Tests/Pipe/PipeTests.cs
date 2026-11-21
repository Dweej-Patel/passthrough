using System.Text;
using Passthrough.Core.Pipe;
using Xunit;

namespace Passthrough.Core.Tests.Pipe;

public sealed class PipeTests
{
    [Fact]
    public void AFrameIsKindLengthPayload()
    {
        var frame = new PipeFrame(PipeKind.Close, "{}"u8.ToArray()).Encode();
        Assert.Equal(new byte[] { 0x45, 0, 0, 0, 2, (byte)'{', (byte)'}' }, frame);
        var data = PipeFrame.Data(PipeKind.Output, 0x01020304, "ab", "xyz"u8).Encode();
        Assert.Equal(new byte[] { 0x13, 0, 0, 0, 10, 1, 2, 3, 4, 2, (byte)'a', (byte)'b', (byte)'x', (byte)'y', (byte)'z' }, data);
        var parsed = new PipeFrame(PipeKind.Output, data[5..]).ReadData()!.Value;
        Assert.Equal((0x01020304u, "ab"), (parsed.Conn, parsed.Session));
        Assert.Equal("xyz"u8.ToArray(), parsed.Data.ToArray());
    }

    [Fact]
    public async Task FramesSurviveBeingSplitAcrossReads()
    {
        var bytes = new PipeFrame(PipeKind.Sessions, "{\"sessions\":[]}"u8.ToArray()).Encode().Concat(new PipeFrame(PipeKind.TrayPing, Array.Empty<byte>()).Encode()).ToArray();
        var reader = new PipeFrameReader(new Trickle(bytes));
        Assert.Equal(PipeKind.Sessions, (await reader.ReadAsync())!.Value.Kind);
        Assert.Equal(PipeKind.TrayPing, (await reader.ReadAsync())!.Value.Kind);
        Assert.Null(await reader.ReadAsync());
    }

    [Fact]
    public async Task AFrameOverOneMebibyteClosesTheConnection()
    {
        var header = new byte[] { PipeKind.Output, 0, 0x10, 0, 1 };
        await Assert.ThrowsAsync<PipeFrameTooLongException>(() => new PipeFrameReader(new MemoryStream(header)).ReadAsync());
    }

    [Theory]
    [InlineData(1, 1, 1, 1, 1)]
    [InlineData(2, 1, 1, 1, 1)]   // the app is newer, within range
    [InlineData(1, 1, 3, 2, null)] // the service needs at least 2
    [InlineData(3, 3, 2, 1, null)] // the app needs at least 3
    public void VersionsMeetAtTheLower(int proto, int min, int peer, int peerMin, int? expected) =>
        Assert.Equal(expected, PipeHandshake.Negotiate(proto, min, peer, peerMin));

    [Fact]
    public async Task TheHandshakeWelcomesATrayAppItTakes()
    {
        var (tray, service) = DuplexStreams.Create();
        var serving = PipeHandshakes.ServerAsync(service, refusal: null, new PipeWelcome { Build = "b", Account = "S-1-5-21-1", Session = 2 });
        var welcome = await PipeHandshakes.ClientAsync(tray, new PipeHello { Build = "b", Pid = 7 });
        Assert.Equal(("S-1-5-21-1", 2, PipeProtocol.Version), (welcome.Account, welcome.Session, welcome.Proto));
        Assert.Equal(7, (await serving)!.Value.Hello.Pid);
    }

    [Theory]
    [InlineData(PipeRefused.ReasonNotAllowed)]
    [InlineData(PipeRefused.ReasonElevated)]
    public async Task ARefusedTrayAppIsToldWhy(string reason)
    {
        var (tray, service) = DuplexStreams.Create();
        var serving = PipeHandshakes.ServerAsync(service, reason, new PipeWelcome());
        var refused = await Assert.ThrowsAsync<PipeRefusedException>(() => PipeHandshakes.ClientAsync(tray, new PipeHello()));
        Assert.Equal(reason, refused.Refused.Reason);
        Assert.Null(await serving);
    }

    [Fact]
    public async Task ATrayAppTooOldForTheServiceIsRefusedForItsVersion()
    {
        var (tray, service) = DuplexStreams.Create();
        _ = PipeHandshakes.ServerAsync(service, null, new PipeWelcome());
        var refused = await Assert.ThrowsAsync<PipeRefusedException>(() =>
            PipeHandshakes.ClientAsync(tray, new PipeHello { Proto = PipeProtocol.Version + 5, MinProto = PipeProtocol.Version + 5 }));
        Assert.Equal(PipeRefused.ReasonVersion, refused.Refused.Reason);
    }

    [Fact]
    public async Task AFrameOtherThanHelloFirstIsNotAnswered()
    {
        var (tray, service) = DuplexStreams.Create();
        var serving = PipeHandshakes.ServerAsync(service, null, new PipeWelcome());
        await tray.WriteAsync(PipeFrame.Json(PipeKind.Sessions, new PipeMessage()).Encode());
        Assert.Null(await serving);
    }

    [Theory]
    [InlineData("S-1-5-21-1", 0, false, PipePeer.Integrity.Medium, PipeRefused.ReasonSession0)]
    [InlineData("S-1-5-21-1", 2, true, PipePeer.Integrity.High, PipeRefused.ReasonElevated)]
    [InlineData("S-1-5-21-1", 2, false, PipePeer.Integrity.High, PipeRefused.ReasonElevated)]
    [InlineData("S-1-5-21-1", 2, false, PipePeer.Integrity.Low, PipeRefused.ReasonLowIntegrity)]
    [InlineData("S-1-5-21-2", 2, false, PipePeer.Integrity.Medium, PipeRefused.ReasonNotAllowed)]
    [InlineData("S-1-5-21-1", 2, false, PipePeer.Integrity.Medium, null)]
    public void OnlyAnAllowedAccountsOwnTrayAppIsTaken(string account, int session, bool elevated, PipePeer.Integrity level, string? reason) =>
        Assert.Equal(reason, PipePeerPolicy.Refusal(new PipePeer(account, session, elevated, level), ["S-1-5-21-1"]));

    [Fact]
    public async Task ASideThatStopsReadingIsCutOff()
    {
        var link = new PipeLink(new Stuck(), service: true, maxQueued: 1000);
        _ = link.RunAsync(_ => ValueTask.CompletedTask);
        Assert.True(link.Send(PipeFrame.Data(PipeKind.Input, 1, "s", new byte[400])));
        Assert.True(link.Send(PipeFrame.Data(PipeKind.Input, 1, "s", new byte[400])));
        Assert.False(link.Send(PipeFrame.Data(PipeKind.Input, 1, "s", new byte[400])));
        Assert.True(link.IsClosed);
    }

    [Fact]
    public async Task PingsAreAnsweredAndNotHandedOn()
    {
        var (a, b) = DuplexStreams.Create();
        var service = new PipeLink(a, service: true, 1 << 20);
        var seen = new List<byte>();
        _ = service.RunAsync(f => { lock (seen) seen.Add(f.Kind); return ValueTask.CompletedTask; });
        await b.WriteAsync(new PipeFrame(PipeKind.TrayPing, Array.Empty<byte>()).Encode());
        await b.WriteAsync(new PipeFrame(PipeKind.Sessions, "{}"u8.ToArray()).Encode());
        var reply = await new PipeFrameReader(b).ReadAsync().WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(PipeKind.ServicePong, reply!.Value.Kind);
        await Task.Delay(50);
        lock (seen) Assert.Equal([PipeKind.Sessions], seen);
        service.Close();
    }

    [Fact]
    public void MessagesCarryNoAccount()
    {
        // No frame can name a Windows account: the service learns it from the tray app's token alone.
        var json = Encoding.UTF8.GetString(PipeFrame.Json(PipeKind.Open, new PipeMessage { Id = 1, Phone = "p" }).Payload.Span);
        Assert.DoesNotContain("account", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(typeof(PipeMessage).GetProperties(), p => p.Name.Contains("Account", StringComparison.Ordinal));
    }

    /// <summary>A stream that hands out one byte per read.</summary>
    private sealed class Trickle(byte[] bytes) : MemoryStream(bytes)
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancel = default) => base.ReadAsync(buffer[..Math.Min(1, buffer.Length)], cancel);
    }

    /// <summary>A stream nobody reads: writes never finish, reads never come.</summary>
    private sealed class Stuck : Stream
    {
        public override bool CanRead => true;
        public override bool CanWrite => true;
        public override bool CanSeek => false;
        public override long Length => 0;
        public override long Position { get => 0; set { } }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => 0;
        public override void SetLength(long value) { }
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancel = default) { await Task.Delay(Timeout.Infinite, cancel); return 0; }
        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancel = default) => await Task.Delay(Timeout.Infinite, cancel);
    }
}
