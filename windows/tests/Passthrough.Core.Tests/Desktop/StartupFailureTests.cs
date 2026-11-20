using Passthrough.Core.Desktop;
using Xunit;

namespace Passthrough.Core.Tests.Desktop;

public class StartupFailureTests
{
    [Fact]
    public void SaysWhatFailed_WhereTheDetailsAre_AndThatTheAppCloses()
    {
        var text = StartupFailure.Message(new IOException("The process cannot access the file 'settings.json'."), @"C:\Users\dee\AppData\Local\Passthrough\passthrough.log");
        Assert.Equal(
            "Passthrough couldn't start.\n\n" +
            "IOException: The process cannot access the file 'settings.json'.\n\n" +
            "Details are in C:\\Users\\dee\\AppData\\Local\\Passthrough\\passthrough.log. Passthrough will now close; start it again once the problem is fixed.",
            text);
    }

    [Fact]
    public void NeverShowsATokenShapedValue()
    {
        var text = StartupFailure.Message(new InvalidOperationException("token AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCdE"), "log");
        Assert.DoesNotContain("AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCdE", text);
    }
}
