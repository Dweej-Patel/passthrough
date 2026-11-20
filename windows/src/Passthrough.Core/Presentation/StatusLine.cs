using System.Globalization;
using Passthrough.Core.Control;

namespace Passthrough.Core.Presentation;

/// <summary>The phone's live facts as one line.</summary>
public static class StatusLine
{
    /// <summary>"{carrier} · {radio} · {battery}%", leaving out what the phone has not said; "" with no status.</summary>
    public static string Format(DeviceStatus? status)
    {
        if (status is null) return "";
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(status.Carrier)) parts.Add(status.Carrier);
        if (!string.IsNullOrEmpty(status.Radio)) parts.Add(status.Radio);
        if (status.Battery is { } battery)
        {
            var percent = Math.Clamp(Math.Round(battery * 100), 0, 100);
            parts.Add(percent.ToString("F0", CultureInfo.InvariantCulture) + "%");
        }
        return string.Join(" · ", parts);
    }
}
