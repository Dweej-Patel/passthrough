using System.Text;
using Passthrough.Core.Control;
using Passthrough.Core.Protocol;
using Xunit;

namespace Passthrough.Core.Tests.Control;

public class LineChannelTests
{
    /// <summary>protocol/README.md: control lines are up to 262144 bytes (the newline not counted).</summary>
    private const int ReadmeLineLimit = 262144;

    /// <summary>A pong padded with an unknown field to exactly <paramref name="bytes"/> bytes, then a newline.</summary>
    private static byte[] PongLine(int bytes)
    {
        const string head = "{\"t\":\"pong\",\"pad\":\"";
        const string tail = "\"}";
        return Encoding.ASCII.GetBytes(head + new string('a', bytes - head.Length - tail.Length) + tail + "\n");
    }

    [Fact]
    public async Task LineAtTheReadmeLimit_IsRead()
    {
        await using var channel = new LineChannel(new MemoryStream(PongLine(ReadmeLineLimit)));

        var m = await channel.ReadAsync(CancellationToken.None);

        Assert.Equal(ControlEnvelope.Pong, m!.T);
    }

    [Fact]
    public async Task LineOneByteOverTheReadmeLimit_IsRefused()
    {
        await using var channel = new LineChannel(new MemoryStream(PongLine(ReadmeLineLimit + 1)));

        await Assert.ThrowsAsync<ProtocolException>(() => channel.ReadAsync(CancellationToken.None));
    }
}
