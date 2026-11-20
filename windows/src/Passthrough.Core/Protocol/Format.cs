using System.Globalization;

namespace Passthrough.Core.Protocol;

public static class Format
{
    private static readonly string[] Units = ["B/s", "KB/s", "MB/s", "GB/s"];

    /// <summary>e.g. "12.4" "MB/s"; the same digits as the Mac's Stats.rate.</summary>
    public static (string Value, string Unit) Rate(double bytesPerSecond)
    {
        var v = bytesPerSecond;
        var i = 0;
        while (v >= 1000 && i < Units.Length - 1) { v /= 1000; i++; }
        var text = i == 0 || v >= 100
            ? v.ToString("F0", CultureInfo.InvariantCulture)
            : v.ToString(v < 10 ? "F2" : "F1", CultureInfo.InvariantCulture);
        return (text, Units[i]);
    }

    /// <summary>"01:05" under an hour, "1:01:05" from an hour.</summary>
    public static string Duration(TimeSpan t)
    {
        var s = (long)t.TotalSeconds;
        return s < 3600
            ? string.Create(CultureInfo.InvariantCulture, $"{s / 60:00}:{s % 60:00}")
            : string.Create(CultureInfo.InvariantCulture, $"{s / 3600}:{s % 3600 / 60:00}:{s % 60:00}");
    }
}
