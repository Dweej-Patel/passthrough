namespace Passthrough.Core.Desktop;

/// <summary>Where the flyout goes: the bottom right of the work area (above the taskbar), sized for the monitor's scale.</summary>
public static class FlyoutPlacement
{
    public const int WidthDip = 360;
    public const int HeightDip = 480;
    public const int MarginDip = 12;

    /// <summary>A monitor's scale from its DPI (96 is 100 %); 1 when the DPI is unknown (0).</summary>
    public static double ScaleFromDpi(uint dpi) => dpi == 0 ? 1.0 : dpi / 96.0;

    /// <summary>The flyout's rectangle in physical pixels inside <paramref name="workArea"/>, shrunk to fit a small one.</summary>
    public static PixelRect Place(PixelRect workArea, double scale)
    {
        var margin = (int)Math.Round(MarginDip * scale);
        var width = Math.Min((int)Math.Round(WidthDip * scale), Math.Max(0, workArea.Width - 2 * margin));
        var height = Math.Min((int)Math.Round(HeightDip * scale), Math.Max(0, workArea.Height - 2 * margin));
        return new PixelRect(workArea.X + workArea.Width - width - margin, workArea.Y + workArea.Height - height - margin, width, height);
    }
}
