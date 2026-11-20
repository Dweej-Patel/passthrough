using Passthrough.Core.Control;
using Passthrough.Core.Presentation;
using Passthrough.Core.Session;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Presentation;

public class StatusLineTests
{
    [Fact]
    public void LeavesOutWhatThePhoneHasNotSaid()
    {
        Assert.Equal("", StatusLine.Format(null));
        Assert.Equal("", StatusLine.Format(new DeviceStatus("n", null, "", null, null, null, null)));
        Assert.Equal("Carrier", StatusLine.Format(new DeviceStatus("n", null, "Carrier", null, null, null, null)));
        Assert.Equal("LTE · 7%", StatusLine.Format(new DeviceStatus("n", "LTE", null, 0.07, null, null, null)));
    }

    [Theory]
    [InlineData(0.0, "0%")]
    [InlineData(0.5, "50%")]
    [InlineData(0.996, "100%")]
    [InlineData(1.0, "100%")]
    [InlineData(1.7, "100%")]
    [InlineData(-0.2, "0%")]
    public void Battery_IsAWholePercent_TheSameInEveryCulture(double battery, string text)
    {
        var saved = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("fr-FR"); // "50 %" with P0
            Assert.Equal(text, StatusLine.Format(new DeviceStatus("n", null, null, battery, null, null, null)));
        }
        finally { System.Globalization.CultureInfo.CurrentCulture = saved; }
    }
}
