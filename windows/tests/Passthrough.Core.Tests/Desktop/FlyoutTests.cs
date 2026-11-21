using Passthrough.Core.Desktop;
using Passthrough.Core.Tests.Fakes;
using Xunit;

namespace Passthrough.Core.Tests.Desktop;

public class FlyoutTests
{
    [Fact]
    public void Toggle_ClickWhileOpen_Closes()
    {
        var toggle = new FlyoutToggle(new FakeTimeProvider());
        Assert.True(toggle.ShouldShowOnClick(visible: false));
        Assert.False(toggle.ShouldShowOnClick(visible: true));
    }

    [Fact]
    public void Toggle_TheClickThatJustHidItByTakingFocus_DoesNotReopenIt()
    {
        var time = new FakeTimeProvider();
        var toggle = new FlyoutToggle(time);

        // Clicking the icon deactivates the open flyout first (it hides), then the click arrives.
        toggle.HiddenByDeactivation();
        time.Advance(FlyoutToggle.ClickWindow - TimeSpan.FromMilliseconds(1));
        Assert.False(toggle.ShouldShowOnClick(visible: false));

        // A later click opens it again.
        toggle.HiddenByDeactivation();
        time.Advance(FlyoutToggle.ClickWindow);
        Assert.True(toggle.ShouldShowOnClick(visible: false));
    }

    [Theory]
    [InlineData(96u, 1.0)]
    [InlineData(144u, 1.5)]
    [InlineData(192u, 2.0)]
    [InlineData(0u, 1.0)] // a failed query
    public void ScaleFromDpi(uint dpi, double scale) => Assert.Equal(scale, FlyoutPlacement.ScaleFromDpi(dpi));

    [Fact]
    public void Place_BottomRightOfTheWorkArea_InPhysicalPixels()
    {
        Assert.Equal(new PixelRect(1920 - 360 - 12, 1032 - 480 - 12, 360, 480), FlyoutPlacement.Place(new PixelRect(0, 0, 1920, 1032), 1.0));
        Assert.Equal(new PixelRect(2560 + 2880 - 540 - 18, 1728 - 720 - 18, 540, 720), FlyoutPlacement.Place(new PixelRect(2560, 0, 2880, 1728), 1.5));
    }

    [Theory]
    [InlineData(300, 300)]
    [InlineData(20, FlyoutPlacement.MinHeightDip)]
    [InlineData(5000, FlyoutPlacement.MaxHeightDip)]
    public void Place_IsAsTallAsItsContent_WithinLimits_AndStaysAtTheBottom(int content, int height)
    {
        Assert.Equal(new PixelRect(1920 - 360 - 12, 1032 - height - 12, 360, height), FlyoutPlacement.Place(new PixelRect(0, 0, 1920, 1032), 1.0, content));
        Assert.Equal(height * 2, FlyoutPlacement.Place(new PixelRect(0, 0, 3840, 2064), 2.0, content).Height);
    }

    [Fact]
    public void Place_FitsAWorkAreaSmallerThanTheFlyout()
    {
        var area = new PixelRect(0, 0, 800, 400);
        var r = FlyoutPlacement.Place(area, 1.0);
        Assert.True(r.X >= area.X && r.Y >= area.Y && r.X + r.Width <= area.X + area.Width && r.Y + r.Height <= area.Y + area.Height, r.ToString());
    }
}
