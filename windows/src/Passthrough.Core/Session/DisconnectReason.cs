using System.Net.Sockets;
using Passthrough.Core.Protocol;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Session;

/// <summary>Sorts why a retryable channel ended, and words it the Mac's way (SessionCoordinator.swift, ADB.swift, USBMuxClient.swift).</summary>
public static class DisconnectReason
{
    /// <summary>The category of <paramref name="error"/> (null: the phone closed the channel cleanly).</summary>
    public static DisconnectCategory Classify(Exception? error) => error switch
    {
        null => DisconnectCategory.PhoneClosed,
        // usbmuxd result 3: the phone refused the port; adb FAIL "closed" or a failed connect (ADB.swift's mapping).
        UsbMuxException { ResultCode: 3 } => DisconnectCategory.AppNotRunning,
        AdbException a when a.Message.Contains("closed") || a.Message.Contains("refused") || a.Message.Contains("connect")
            => DisconnectCategory.AppNotRunning,
        SocketException { SocketErrorCode: SocketError.ConnectionRefused } => DisconnectCategory.AppNotRunning,
        TimeoutException => DisconnectCategory.NoAnswer,
        ProtocolException => DisconnectCategory.ProtocolError,
        _ => DisconnectCategory.ConnectionLost,
    };

    /// <summary>What the row says while the phone is tried again; <paramref name="kind"/> is "iPhone" or "Android phone".</summary>
    public static string Describe(DisconnectCategory category, string kind) => category switch
    {
        DisconnectCategory.PhoneClosed => $"The {kind} closed the connection.",
        DisconnectCategory.AppNotRunning => $"Passthrough isn't running on the {kind}. Start it there, then connect.",
        DisconnectCategory.NoAnswer => $"The {kind} stopped responding.",
        DisconnectCategory.ProtocolError => $"The {kind} sent something this PC couldn't read. Update Passthrough on both.",
        _ => $"Lost the connection to the {kind}.",
    };
}
