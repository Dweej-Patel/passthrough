using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Passthrough.Windows.Shell;

/// <summary>
/// A session's environment: the account's own, as a new sign-in would get it (CreateEnvironmentBlock), never this
/// process's, plus what says the terminal is Passthrough's. The session manager adds the session's id.
/// </summary>
public static class UserEnvironment
{
    public static IReadOnlyDictionary<string, string> Create()
    {
        Native.Check(Native.OpenProcessToken(Native.GetCurrentProcess(), Native.TokenQuery | Native.TokenDuplicate, out var token), "OpenProcessToken");
        using (token)
        {
            Native.Check(Native.CreateEnvironmentBlock(out var block, token, false), "CreateEnvironmentBlock");
            try { return WithTerminal(Parse(block)); }
            finally { Native.DestroyEnvironmentBlock(block); }
        }
    }

    /// <summary>What every session says about its terminal (ConPTY passes 24-bit colour through).</summary>
    internal static Dictionary<string, string> WithTerminal(Dictionary<string, string> environment)
    {
        environment["TERM"] = "xterm-256color";
        environment["COLORTERM"] = "truecolor";
        environment["TERM_PROGRAM"] = "Passthrough";
        return environment;
    }

    private static Dictionary<string, string> Parse(IntPtr block)
    {
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var p = block; ;)
        {
            var entry = Marshal.PtrToStringUni(p)!;
            if (entry.Length == 0) break;
            p += (entry.Length + 1) * sizeof(char);
            // "=C:=C:\..." entries name their variable after the leading '='.
            var equals = entry.IndexOf('=', 1);
            if (equals > 0) environment[entry[..equals]] = entry[(equals + 1)..];
        }
        return environment;
    }

    /// <summary>The account's home folder, where a session starts.</summary>
    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>
    /// This process runs elevated (started as administrator, or UAC is off). It then hosts no shells: a phone's would
    /// run as administrator, which Passthrough never allows.
    /// </summary>
    public static bool IsElevated()
    {
        if (!Native.OpenProcessToken(Native.GetCurrentProcess(), Native.TokenQuery, out SafeAccessTokenHandle token)) return true;
        using (token)
            return !Native.GetTokenInformation(token, Native.TokenElevation, out var elevated, sizeof(int), out _) || elevated != 0;
    }
}
