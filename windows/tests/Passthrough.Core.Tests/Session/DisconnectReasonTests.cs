using System.Net.Sockets;
using Passthrough.Core.Protocol;
using Passthrough.Core.Session;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Session;

public class DisconnectReasonTests
{
    public static TheoryData<Exception?, DisconnectCategory> Cases => new()
    {
        { null, DisconnectCategory.PhoneClosed },
        { new UsbMuxException(3), DisconnectCategory.AppNotRunning },
        { new UsbMuxException(2), DisconnectCategory.ConnectionLost },
        { new AdbException("closed"), DisconnectCategory.AppNotRunning },
        { new AdbException("connection refused"), DisconnectCategory.AppNotRunning },
        { new AdbException("failed to connect to tcp:7891"), DisconnectCategory.AppNotRunning },
        { new AdbException("device offline"), DisconnectCategory.ConnectionLost },
        { new SocketException((int)SocketError.ConnectionRefused), DisconnectCategory.UsbServiceDown },
        { new TimeoutException("The phone stopped responding"), DisconnectCategory.NoAnswer },
        { new ProtocolException("Not a control message"), DisconnectCategory.ProtocolError },
        { new IOException("reset"), DisconnectCategory.ConnectionLost },
        { new EndOfStreamException("adb closed the connection"), DisconnectCategory.ConnectionLost },
    };

    [Theory]
    [MemberData(nameof(Cases))]
    public void Classify(Exception? error, DisconnectCategory expected) => Assert.Equal(expected, DisconnectReason.Classify(error));

    [Theory]
    [InlineData(DisconnectCategory.PhoneClosed, "The iPhone closed the connection.")]
    [InlineData(DisconnectCategory.AppNotRunning, "Passthrough isn't running on the iPhone. Start it there, then connect.")]
    [InlineData(DisconnectCategory.UsbServiceDown, "Apple Devices isn't answering on this PC. Open Apple Devices, then connect.")]
    [InlineData(DisconnectCategory.NoAnswer, "The iPhone stopped responding.")]
    [InlineData(DisconnectCategory.ProtocolError, "The iPhone sent something this PC couldn't read. Update Passthrough on both.")]
    [InlineData(DisconnectCategory.ConnectionLost, "Lost the connection to the iPhone.")]
    public void Describe(DisconnectCategory category, string message) => Assert.Equal(message, DisconnectReason.Describe(category, PhoneKind.IPhone));

    [Fact]
    public void Describe_UsbServiceDown_NamesAdbForAndroid() =>
        Assert.Equal("adb isn't answering on this PC. Passthrough keeps trying.", DisconnectReason.Describe(DisconnectCategory.UsbServiceDown, PhoneKind.Android));
}
