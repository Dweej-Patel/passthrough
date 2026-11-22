using Passthrough.Windows.Client;
using Xunit;

namespace Passthrough.Windows.Tests;

public sealed class TermBridgeTests
{
    [Fact]
    public void ATitleKeepsTheNameButNoControlOrFormatCharacters()
    {
        Assert.Equal("Bob's Mac;calc · zsh", TermBridge.Title("Bob's Mac;calc", "zsh"));
        Assert.Equal("Mac]0;x · shell", TermBridge.Title("Mac\u001b]0;x\u0007", null));
        Assert.Equal("Macevil · shell", TermBridge.Title("Mac‮evil", null));
    }
}
