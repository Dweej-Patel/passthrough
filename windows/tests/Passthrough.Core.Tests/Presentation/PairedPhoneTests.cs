using Passthrough.Core.Presentation;
using Xunit;

namespace Passthrough.Core.Tests.Presentation;

public class PairedPhoneTests
{
    [Fact]
    public void EachSlot_NamedByItsSavedName_ElseItsKind_WithTheShortId()
    {
        var names = new Dictionary<string, string> { ["token.iphone.00008110-001A2B3C"] = "Dee's iPhone" };
        var list = PairedPhone.List(
            ["token.android.R58M123", "token.ipad.00008027-BBBB", "token.iphone.00008110-001A2B3C", "token.iphone.0001"],
            slot => names.GetValueOrDefault(slot));

        Assert.Equal([
            new PairedPhone("token.android.R58M123", "Android phone", "R58M123"),
            new PairedPhone("token.ipad.00008027-BBBB", "iPad", "00008027…"),
            new PairedPhone("token.iphone.00008110-001A2B3C", "Dee's iPhone", "iPhone · 00008110…"),
            new PairedPhone("token.iphone.0001", "iPhone", "0001"),
        ], list);
    }

    [Fact]
    public void AnUnknownSlot_IsListedAsItIs() =>
        Assert.Equal([new PairedPhone("something.else", "something.else", "")], PairedPhone.List(["something.else"], _ => null));
}
