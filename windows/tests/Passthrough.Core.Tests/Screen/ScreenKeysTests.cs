using Passthrough.Core.Screen;
using Passthrough.Core.Shell;
using Xunit;
using A = Passthrough.Core.Screen.ScreenKeyAction;
using K = Passthrough.Core.Screen.ScreenKeys;

namespace Passthrough.Core.Tests.Screen;

public sealed class ScreenKeysTests
{
    [Theory]
    [InlineData(K.VkReturn, 0xFF0Du)]
    [InlineData(K.VkTab, 0xFF09u)]
    [InlineData(K.VkBack, 0xFF08u)]
    [InlineData(K.VkDelete, 0xFFFFu)]
    [InlineData(K.VkEscape, 0xFF1Bu)]
    [InlineData(K.VkLeft, 0xFF51u)]
    [InlineData(K.VkUp, 0xFF52u)]
    [InlineData(K.VkRight, 0xFF53u)]
    [InlineData(K.VkDown, 0xFF54u)]
    [InlineData(K.VkHome, 0xFF50u)]
    [InlineData(K.VkEnd, 0xFF57u)]
    [InlineData(K.VkPrior, 0xFF55u)]
    [InlineData(K.VkNext, 0xFF56u)]
    [InlineData(K.VkF1, 0xFFBEu)]
    [InlineData(K.VkF12, 0xFFC9u)]
    public void SpecialKeysAreTheirKeysyms(int vk, uint keysym)
    {
        Assert.Equal(keysym, K.SpecialKeysym(vk));
        Assert.Equal(new A.Key(keysym, ScreenModifiers.None), K.Down(vk, PcModifiers.None, '\0', ctrlIsCommand: false));
    }

    [Theory]
    [InlineData(K.VkInsert)]
    [InlineData(0x7C)] // F13
    [InlineData(K.VkF24)]
    public void InsertAndF13UpAreNotSent(int vk) => Assert.Null(K.SpecialKeysym(vk));

    [Fact]
    public void ModifiersMapAndCtrlActsAsCommandSwapsAltAndCtrl()
    {
        Assert.Equal(ScreenModifiers.Command, K.Modifiers(PcModifiers.Alt, false));
        Assert.Equal(ScreenModifiers.Control, K.Modifiers(PcModifiers.Ctrl, false));
        Assert.Equal(ScreenModifiers.Option, K.Modifiers(PcModifiers.Windows, false));
        Assert.Equal(ScreenModifiers.Shift, K.Modifiers(PcModifiers.Shift, false));
        Assert.Equal(ScreenModifiers.Control, K.Modifiers(PcModifiers.Alt, true));
        Assert.Equal(ScreenModifiers.Command, K.Modifiers(PcModifiers.Ctrl, true));
        Assert.Equal(ScreenModifiers.Option, K.Modifiers(PcModifiers.Windows, true));
    }

    [Fact]
    public void ShortcutsAreTheUnshiftedKeyWithItsModifiers()
    {
        Assert.Equal(new A.Key('c', ScreenModifiers.Command), K.Down('C', PcModifiers.Alt, 'C', false));            // Alt+C copies
        Assert.Equal(new A.Key('c', ScreenModifiers.Control), K.Down('C', PcModifiers.Ctrl, 'C', false));           // Ctrl+C interrupts
        Assert.Equal(new A.Key('e', ScreenModifiers.Option), K.Down('E', PcModifiers.Windows, 'E', false));         // Win+E is ⌥E
        Assert.Equal(new A.Key(' ', ScreenModifiers.Command), K.Down(0x20, PcModifiers.Alt, ' ', false));           // Alt+Space: Spotlight
        Assert.Equal(new A.Key('z', ScreenModifiers.Command | ScreenModifiers.Shift), K.Down('Z', PcModifiers.Alt | PcModifiers.Shift, 'Z', false));
        Assert.Equal(new A.Key(0xFF51, ScreenModifiers.Control), K.Down(K.VkLeft, PcModifiers.Ctrl, '\0', false));
        Assert.Equal(new A.Key('c', ScreenModifiers.Command), K.Down('C', PcModifiers.Ctrl, 'C', ctrlIsCommand: true));
    }

    [Fact]
    public void TheRestIsTyping()
    {
        Assert.IsType<A.Text>(K.Down('A', PcModifiers.None, 'A', false));
        Assert.IsType<A.Text>(K.Down('A', PcModifiers.Shift, 'A', false));
        Assert.IsType<A.Text>(K.Down('Q', PcModifiers.Ctrl | PcModifiers.Alt, 'Q', false, altGr: true)); // German AltGr+Q types @
        Assert.IsType<A.Text>(K.Down(K.VkReturn, PcModifiers.None, '\r', false, composing: true));       // an input method takes Return
    }

    [Fact]
    public void ModifiersAloneSendNothingAndTheMenuKeyIsFn()
    {
        foreach (var vk in new[] { K.VkShift, K.VkControl, K.VkMenu, K.VkLWin, K.VkRWin, K.VkCapital, 0xA0, 0xA5 })
            Assert.IsType<A.Nothing>(K.Down(vk, PcModifiers.None, '\0', false));
        Assert.Equal(new A.Function(true), K.Down(K.VkApps, PcModifiers.None, '\0', false));
        Assert.Equal(new A.Function(false), K.Up(K.VkApps));
        Assert.IsType<A.Nothing>(K.Up('A'));
    }

    [Fact]
    public void ThisPcKeepsItsOwnKeys()
    {
        Assert.IsType<A.Local>(K.Down(K.VkTab, PcModifiers.Alt, '\t', false));
        Assert.IsType<A.Local>(K.Down(K.VkTab, PcModifiers.Alt | PcModifiers.Shift, '\t', false));
        Assert.IsType<A.Local>(K.Down(K.VkEscape, PcModifiers.Alt, '\0', false));
        Assert.IsType<A.Local>(K.Down(K.VkF4, PcModifiers.Alt, '\0', false));
        Assert.IsType<A.Local>(K.Down(K.VkCancel, PcModifiers.Ctrl | PcModifiers.Alt, '\0', false));
        Assert.IsType<A.Local>(K.Down(K.VkSnapshot, PcModifiers.None, '\0', false));
        Assert.IsType<A.Local>(K.Down('S', PcModifiers.Windows | PcModifiers.Shift, 'S', false));
        Assert.IsType<A.Local>(K.Down(0xAF, PcModifiers.None, '\0', false)); // volume up
        Assert.IsType<A.Key>(K.Down(K.VkTab, PcModifiers.Ctrl, '\t', false));
        Assert.IsType<A.Local>(K.Down(K.VkTab, PcModifiers.Alt, '\t', false, composing: true));
    }

    [Fact]
    public void KeysymsFollowRfbKeys()
    {
        Assert.Equal(0x61u, K.Keysym('a'));
        Assert.Equal(0xE9u, K.Keysym('é'));
        Assert.Equal(0xFF0Du, K.Keysym('\n'));
        Assert.Equal(0x010020ACu, K.Keysym('€'));
        Assert.Null(K.Keysym('\0'));
        Assert.Null(K.Keysym('\uD83D'));
    }
}

public sealed class ScrollAndFrameTests
{
    private sealed class Clock : TimeProvider
    {
        public long Now;
        public override long GetTimestamp() => Now;
        public override long TimestampFrequency => 1000;
    }

    [Fact]
    public void ANotchIsAHundredViewPixelsScaledToTheStream()
    {
        var clock = new Clock { Now = 1 };
        var s = new ScrollScale();
        Assert.Equal((0, 100), s.Wheel(120, false, 1, clock.Now, clock));
        Assert.Equal((0, -200), s.Wheel(-120, false, 2, clock.Now, clock));
        Assert.Equal((-100, 0), s.Wheel(120, true, 1, clock.Now, clock)); // horizontal positive: negative dx
    }

    [Fact]
    public void FractionsCarryUntilAPause()
    {
        var clock = new Clock { Now = 1 };
        var s = new ScrollScale();
        Assert.Equal((0, 0), s.Wheel(1, false, 1, clock.Now, clock));    // 0.83
        Assert.Equal((0, 1), s.Wheel(1, false, 1, clock.Now += 10, clock)); // 1.67
        Assert.Equal((0, 1), s.Wheel(1, false, 1, clock.Now += 10, clock)); // 0.67 + 0.83 = 1.5
        clock.Now += 1000;
        Assert.Equal((0, 0), s.Wheel(1, false, 1, clock.Now, clock));    // after a pause the carry is gone
    }

    [Fact]
    public void ThePictureIsLetterboxedAndPointsClamp()
    {
        var p = ScreenFrame.Picture(1000, 1000, 1600, 1000);
        Assert.Equal((0, 187.5, 1000, 625), p);
        Assert.Equal((0.5, 0.5, true), ScreenFrame.StreamPoint(500, 500, p));
        Assert.Equal((0.0, 0.0, false), ScreenFrame.StreamPoint(-5, 10, p));
        Assert.Equal(1280, ScreenFrame.RequestedSide([1024]));
        Assert.Equal(3840, ScreenFrame.RequestedSide([1920, 3840]));
        Assert.Equal(4096, ScreenFrame.RequestedSide([7680]));
        Assert.Equal(2560, ScreenFrame.RequestedSide([]));
    }

    [Fact]
    public void AFittedDisplayIsTheViewsPixels_WithAsManyPointsAsThisPcHas()
    {
        // 100 %: the stream is the view's pixels; the Mac's display is twice that, so it has as many points as the view.
        Assert.Equal((1920, 1000, 200), ScreenFrame.Fitted(1920, 1000, 1));
        Assert.Equal((2400, 1350, 133), ScreenFrame.Fitted(1600, 900, 1.5));
        Assert.Equal((2560, 1440, 100), ScreenFrame.Fitted(1280, 720, 2));
        // Even sides, within what the wire and the Mac take; a bad scale reads as 100 %.
        Assert.Equal((1000, 480, 200), ScreenFrame.Fitted(1001, 301, 1));
        Assert.Equal((4096, 4096, 57), ScreenFrame.Fitted(5000, 3000, 3.5));
        Assert.Equal((800, 600, 200), ScreenFrame.Fitted(800, 600, double.NaN));
    }

    [Fact]
    public void RefusalsSayWhatToDo()
    {
        Assert.Contains("no longer lets this PC", ScreenFrame.Refusal(ShellError.NotAuthorized, "MacBook"));
        Assert.Contains("Screen Recording", ScreenFrame.Refusal(ShellError.ScreenVideoUnavailable, "MacBook"));
        Assert.Contains("as often as it allows", ScreenFrame.Refusal(ShellError.TooManyScreens, "MacBook"));
        Assert.Equal("Mac", ScreenFrame.Clean("‮Ma\u0007c"));
    }
}
