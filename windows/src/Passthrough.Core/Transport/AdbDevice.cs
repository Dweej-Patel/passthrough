namespace Passthrough.Core.Transport;

/// <summary>An Android phone as the adb server reports it.</summary>
public sealed record AdbDevice(string Serial, string State, string? Model)
{
    /// <summary>True when the phone is authorised and online (state "device").</summary>
    public bool IsUsable => State == "device";

    /// <summary>Wi-Fi adb (host:port, mDNS) and emulators are not USB-attached phones.</summary>
    public static bool IsIgnored(string serial) =>
        serial.StartsWith("emulator-", StringComparison.Ordinal)
        || serial.Contains(':')
        || serial.Contains("_adb-tls-connect._tcp", StringComparison.Ordinal);
}
