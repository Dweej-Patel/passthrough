namespace Passthrough.Core.Transport;

/// <summary>usbmuxd answered a request with a non-zero result code (2 = no such device, 3 = refused, 6 = version mismatch).</summary>
public sealed class UsbMuxException(int resultCode) : Exception($"usbmuxd error {resultCode}")
{
    public int ResultCode { get; } = resultCode;
}
