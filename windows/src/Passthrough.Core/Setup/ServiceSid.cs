using System.Security.Cryptography;
using System.Text;

namespace Passthrough.Core.Setup;

/// <summary>
/// A service's SID (<c>NT SERVICE\&lt;name&gt;</c>), known before the service exists: <c>S-1-5-80-</c> and the SHA-1 of
/// the upper-cased name in UTF-16LE as five little-endian 32-bit numbers. Folders, the pipe and the service's own
/// security name it, so it is computed, not looked up.
/// </summary>
public static class ServiceSid
{
    public static string For(string serviceName)
    {
        var hash = SHA1.HashData(Encoding.Unicode.GetBytes(serviceName.ToUpperInvariant()));
        var parts = Enumerable.Range(0, 5).Select(i => BitConverter.ToUInt32(hash, i * 4).ToString(System.Globalization.CultureInfo.InvariantCulture));
        return "S-1-5-80-" + string.Join('-', parts);
    }
}
