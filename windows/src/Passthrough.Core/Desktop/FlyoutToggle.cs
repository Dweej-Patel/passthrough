namespace Passthrough.Core.Desktop;

/// <summary>
/// Makes the tray icon open and close the flyout. Clicking the icon while the flyout is open first takes focus from it
/// (it hides itself) and only then delivers the click; a click that soon after such a hide is that same click, so it
/// leaves the flyout closed.
/// </summary>
public sealed class FlyoutToggle(TimeProvider time)
{
    /// <summary>How soon after a hide-on-deactivation a click counts as the click that caused it.</summary>
    public static readonly TimeSpan ClickWindow = TimeSpan.FromMilliseconds(300);

    private long? _hiddenAt;

    /// <summary>The flyout hid itself because it lost focus.</summary>
    public void HiddenByDeactivation() => _hiddenAt = time.GetTimestamp();

    /// <summary>On an icon click: true to show the flyout; false to hide it (or leave it hidden).</summary>
    public bool ShouldShowOnClick(bool visible)
    {
        if (visible) return false;
        var justHidden = _hiddenAt is { } at && time.GetElapsedTime(at) < ClickWindow;
        _hiddenAt = null;
        return !justHidden;
    }
}
