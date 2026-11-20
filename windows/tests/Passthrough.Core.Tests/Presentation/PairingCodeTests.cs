using Passthrough.Core.Control;
using Passthrough.Core.Presentation;
using Passthrough.Core.Session;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Presentation;

public class PairingCodeTests
{
    [Theory]
    [InlineData("123456", "123456")]
    [InlineData(" 123 456 ", "123456")]
    [InlineData("123-456", "123456")]
    [InlineData("12345", null)]
    [InlineData("1234567", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    [InlineData("１２３４５６", null)] // full-width digits are not what the phone shows
    public void Normalize(string? typed, string? code) => Assert.Equal(code, PairingCode.Normalize(typed));
}
