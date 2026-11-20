namespace Passthrough.Core.Transport;

/// <summary>An Android phone as the adb server reports it.</summary>
/// <param name="IsUsb">Attached over a USB cable: the track line carries a <c>usb:</c> property (adb over Wi-Fi and emulators do not).</param>
public sealed record AdbDevice(string Serial, string State, string? Model, bool IsUsb)
{
    /// <summary>True when the phone is authorised and online (state "device").</summary>
    public bool IsUsable => State == "device";
}
