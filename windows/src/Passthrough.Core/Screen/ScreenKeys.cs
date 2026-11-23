using System.Text;

namespace Passthrough.Core.Screen;

/// <summary>What one key press on this PC becomes for the Mac (stage 8 b3).</summary>
public abstract record ScreenKeyAction
{
    /// <summary>Left to this PC (Alt+Tab, Alt+F4, PrintScreen, media keys…), not swallowed.</summary>
    public sealed record Local : ScreenKeyAction;
    /// <summary>Sent as a key press with modifiers, and swallowed.</summary>
    public sealed record Key(uint Keysym, ScreenModifiers Modifiers) : ScreenKeyAction;
    /// <summary>The Mac's Fn key goes down or up (this PC's Menu key, held).</summary>
    public sealed record Function(bool Down) : ScreenKeyAction;
    /// <summary>Typing: left to the text box, whose committed text is sent as <c>text</c>.</summary>
    public sealed record Text : ScreenKeyAction;
    /// <summary>A modifier alone, or a key with nothing to send: swallowed, nothing sent.</summary>
    public sealed record Nothing : ScreenKeyAction;
}

/// <summary>This PC's modifier keys held, as Windows names them.</summary>
[Flags]
public enum PcModifiers { None = 0, Shift = 1, Ctrl = 2, Alt = 4, Windows = 8 }

/// <summary>
/// The key table (stage 8 b3): virtual keys to X keysyms (RFBKeys.swift), this PC's modifiers to the Mac's
/// (Alt ⌘, Ctrl ⌃, Windows ⌥, Shift ⇧; "Ctrl acts as ⌘" swaps Alt and Ctrl), the keys left to this PC, and the rule for
/// shortcuts: with ⌘, ⌃ or ⌥ held, the key the character types unshifted on this PC's layout.
/// </summary>
public static class ScreenKeys
{
    public const int VkBack = 0x08, VkTab = 0x09, VkReturn = 0x0D, VkShift = 0x10, VkControl = 0x11, VkMenu = 0x12, VkPause = 0x13;
    public const int VkCapital = 0x14, VkEscape = 0x1B, VkPrior = 0x21, VkNext = 0x22, VkEnd = 0x23, VkHome = 0x24;
    public const int VkLeft = 0x25, VkUp = 0x26, VkRight = 0x27, VkDown = 0x28, VkSnapshot = 0x2C, VkInsert = 0x2D, VkDelete = 0x2E;
    public const int VkLWin = 0x5B, VkRWin = 0x5C, VkApps = 0x5D, VkF1 = 0x70, VkF4 = 0x73, VkF12 = 0x7B, VkF24 = 0x87;
    public const int VkCancel = 0x03; // Ctrl+Break

    private static readonly Dictionary<int, uint> Special = new()
    {
        [VkReturn] = 0xFF0D, [VkTab] = 0xFF09, [VkBack] = 0xFF08, [VkDelete] = 0xFFFF, [VkEscape] = 0xFF1B,
        [VkLeft] = 0xFF51, [VkUp] = 0xFF52, [VkRight] = 0xFF53, [VkDown] = 0xFF54,
        [VkHome] = 0xFF50, [VkEnd] = 0xFF57, [VkPrior] = 0xFF55, [VkNext] = 0xFF56,
    };

    /// <summary>The keysym of a key that isn't text (Return, arrows, F1–F12…); null for the rest. Insert and F13 up aren't sent.</summary>
    public static uint? SpecialKeysym(int vk) =>
        Special.TryGetValue(vk, out var k) ? k : vk is >= VkF1 and <= VkF12 ? 0xFFBEu + (uint)(vk - VkF1) : null;

    /// <summary>The Mac's modifiers for this PC's.</summary>
    public static ScreenModifiers Modifiers(PcModifiers held, bool ctrlIsCommand)
    {
        var m = ScreenModifiers.None;
        if (held.HasFlag(PcModifiers.Shift)) m |= ScreenModifiers.Shift;
        if (held.HasFlag(PcModifiers.Windows)) m |= ScreenModifiers.Option;
        if (held.HasFlag(PcModifiers.Alt)) m |= ctrlIsCommand ? ScreenModifiers.Control : ScreenModifiers.Command;
        if (held.HasFlag(PcModifiers.Ctrl)) m |= ctrlIsCommand ? ScreenModifiers.Command : ScreenModifiers.Control;
        return m;
    }

    /// <summary>Keys this PC keeps: switching windows, closing the view, full screen, screenshots, media and volume.</summary>
    public static bool IsLocal(int vk, PcModifiers held) =>
        (held.HasFlag(PcModifiers.Alt) && vk is VkTab or VkEscape or VkF4)
        || (held.HasFlag(PcModifiers.Ctrl) && held.HasFlag(PcModifiers.Alt) && vk is VkCancel or VkPause)
        || vk == VkSnapshot
        || (held.HasFlag(PcModifiers.Windows) && held.HasFlag(PcModifiers.Shift) && vk == 'S')
        || vk is >= 0xA6 and <= 0xB7; // browser, volume and media keys

    /// <summary>
    /// What a key-down becomes. <paramref name="unshifted"/> is the character the key types unshifted on this PC's
    /// layout (MapVirtualKeyEx to char), 0 when none; <paramref name="altGr"/> when right Alt is this layout's AltGr
    /// (then the key is typing, whatever else is held); <paramref name="composing"/> while an input method composes.
    /// </summary>
    public static ScreenKeyAction Down(int vk, PcModifiers held, char unshifted, bool ctrlIsCommand, bool altGr = false, bool composing = false)
    {
        if (IsLocal(vk, held)) return new ScreenKeyAction.Local();
        if (composing) return new ScreenKeyAction.Text();
        if (vk == VkApps) return new ScreenKeyAction.Function(true);
        if (vk is VkShift or VkControl or VkMenu or VkLWin or VkRWin or VkCapital or (>= 0xA0 and <= 0xA5)) return new ScreenKeyAction.Nothing();
        if (altGr) return new ScreenKeyAction.Text();
        var modifiers = Modifiers(held, ctrlIsCommand);
        if (SpecialKeysym(vk) is { } special) return new ScreenKeyAction.Key(special, modifiers);
        if ((modifiers & (ScreenModifiers.Command | ScreenModifiers.Control | ScreenModifiers.Option)) != 0)
            return Keysym(char.ToLowerInvariant(unshifted)) is { } keysym ? new ScreenKeyAction.Key(keysym, modifiers) : new ScreenKeyAction.Nothing();
        return new ScreenKeyAction.Text();
    }

    /// <summary>What a key-up becomes: only the Menu key (the Mac's Fn) says anything.</summary>
    public static ScreenKeyAction Up(int vk) => vk == VkApps ? new ScreenKeyAction.Function(false) : new ScreenKeyAction.Nothing();

    /// <summary>The keysym for one typed character (RFBKeys.keysym(for:)): Latin-1 as itself, newline and tab as their keys, else Unicode.</summary>
    public static uint? Keysym(char c)
    {
        if (c is '\n' or '\r') return 0xFF0D;
        if (c == '\t') return 0xFF09;
        if (c == '\0' || char.IsSurrogate(c)) return null;
        if (c is >= (char)0x20 and <= (char)0x7E or >= (char)0xA0 and <= (char)0xFF) return c;
        return char.IsControl(c) ? null : 0x0100_0000u + c;
    }
}

/// <summary>
/// Wheel and touchpad deltas as the Mac's scroll (stage 8 b3): a notch (120) is 100 view pixels, a precision touchpad
/// follows the fingers; view pixels times stream pixels per view pixel; vertical positive is earlier content (dy up),
/// horizontal positive is negative dx. Fractions are carried to the next event and dropped after a pause.
/// </summary>
public sealed class ScrollScale
{
    public static readonly TimeSpan Pause = TimeSpan.FromMilliseconds(150);
    private double _x, _y;
    private long _last;

    /// <param name="delta">The wheel delta (120 a notch).</param>
    /// <param name="horizontal">A horizontal wheel or a sideways swipe.</param>
    /// <param name="streamPerView">Stream pixels per view pixel (stream width over picture width).</param>
    /// <param name="now">A timestamp in <see cref="TimeProvider"/> ticks.</param>
    public (int Dx, int Dy) Wheel(int delta, bool horizontal, double streamPerView, long now, TimeProvider? time = null)
    {
        var t = time ?? TimeProvider.System;
        if (_last != 0 && t.GetElapsedTime(_last, now) > Pause) _x = _y = 0;
        _last = now;
        var pixels = delta * 100.0 / 120 * streamPerView;
        if (horizontal) _x -= pixels;
        else _y += pixels;
        var dx = (int)Math.Truncate(_x);
        var dy = (int)Math.Truncate(_y);
        _x -= dx;
        _y -= dy;
        return (Math.Clamp(dx, short.MinValue, short.MaxValue), Math.Clamp(dy, short.MinValue, short.MaxValue));
    }
}

/// <summary>Where the stream sits in a view, and what size to ask the Mac for.</summary>
public static class ScreenFrame
{
    /// <summary>The stream aspect-fitted (letterboxed) in a view of <paramref name="viewWidth"/>×<paramref name="viewHeight"/>.</summary>
    public static (double X, double Y, double Width, double Height) Picture(double viewWidth, double viewHeight, int streamWidth, int streamHeight)
    {
        if (streamWidth <= 0 || streamHeight <= 0 || viewWidth <= 0 || viewHeight <= 0) return (0, 0, Math.Max(viewWidth, 0), Math.Max(viewHeight, 0));
        var scale = Math.Min(viewWidth / streamWidth, viewHeight / streamHeight);
        var w = streamWidth * scale;
        var h = streamHeight * scale;
        return ((viewWidth - w) / 2, (viewHeight - h) / 2, w, h);
    }

    /// <summary>A point in the view as 0…1 across the stream, clamped; and whether it was on the picture.</summary>
    public static (double X, double Y, bool Inside) StreamPoint(double x, double y, (double X, double Y, double Width, double Height) picture)
    {
        var inside = x >= picture.X && y >= picture.Y && x < picture.X + picture.Width && y < picture.Y + picture.Height;
        return (Math.Clamp((x - picture.X) / Math.Max(picture.Width, 1), 0, 1), Math.Clamp((y - picture.Y) / Math.Max(picture.Height, 1), 0, 1), inside);
    }

    /// <summary>The side to ask for (fit <c>mac</c>): the largest monitor's longest side in pixels, 1280…4096.</summary>
    public static int RequestedSide(IEnumerable<int> monitorLongestSides) => Math.Clamp(monitorLongestSides.DefaultIfEmpty(2560).Max(), 1280, 4096);

    /// <summary>
    /// The display to ask a Mac for (fit <c>device</c>) so its picture fills a view of this many device-independent
    /// pixels on a monitor at <paramref name="scale"/> (1 at 100 %): the stream is the view's own pixels (even, 480…4096
    /// a side), and <c>Space</c> makes the Mac's display that many points, so its text is the size this PC's is. The
    /// Mac's display has two pixels to the point: at 100 % it is asked for twice the stream (space 200), at 200 % the same.
    /// </summary>
    public static (int Width, int Height, int Space) Fitted(double dipWidth, double dipHeight, double scale)
    {
        if (!double.IsFinite(scale) || scale <= 0) scale = 1;
        int Side(double dip) => Math.Clamp(double.IsFinite(dip) ? (int)Math.Round(dip * scale) : 0, 480, 4096) & ~1;
        return (Side(dipWidth), Side(dipHeight), Math.Clamp((int)Math.Round(200 / scale), 50, 200));
    }

    /// <summary>What a refusal of the screen says (RemoteScreenWindow.swift's wording, for a PC).</summary>
    public static string Refusal(Shell.ShellError error, string name) => error switch
    {
        Shell.ShellError.NotAuthorized or Shell.ShellError.ScreenNotAllowed => $"{name} no longer lets this PC see its screen. Add it again, or share it from your phone.",
        Shell.ShellError.ScreenVideoUnavailable or Shell.ShellError.ScreenUnavailable => $"{name} can't stream its screen yet. On {name}, allow Passthrough Screen Recording and Accessibility.",
        Shell.ShellError.TooManyScreens => $"{name} is already showing its screen as often as it allows. Close another view of it first.",
        _ => $"{name} refused the connection ({Shell.ShellErrorWire.ToWire(error)}).",
    };

    /// <summary>Names cleaned for a window title: control and bidi characters dropped.</summary>
    public static string Clean(string name)
    {
        var b = new StringBuilder(name.Length);
        foreach (var c in name) if (!char.IsControl(c) && c is not (>= '‪' and <= '‮') and not (>= '⁦' and <= '⁩')) b.Append(c);
        return b.Length == 0 ? "this computer" : b.ToString();
    }
}
