using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using Passthrough.Core.Storage;
using Passthrough.Core.Trust;

namespace Passthrough.Windows.Trust;

/// <summary>
/// "Is it you" without Windows Hello: Windows' own credential prompt for this account, and the password it returns
/// checked with a sign-in of its own (<c>LogonUser</c>), which must give this same account. The password is never kept:
/// its buffers are wiped before they are freed. Wrong passwords count toward Windows' own lockout.
/// </summary>
public static unsafe class WindowsPassword
{
    public const int Tries = 3;

    /// <summary>True once the person typed this account's password; false when they cancelled or it was wrong <see cref="Tries"/> times.</summary>
    public static Task<bool> ConfirmAsync(string message, Action<string>? log = null) => Task.Run(() => Confirm(message, log));

    private static bool Confirm(string message, Action<string>? log)
    {
        using var me = WindowsIdentity.GetCurrent();
        var error = 0;
        for (var attempt = 0; attempt < Tries; attempt++)
        {
            var info = new CREDUI_INFO { cbSize = sizeof(CREDUI_INFO), hwndParent = OwnForegroundWindow() };
            fixed (char* text = message, caption = "Passthrough")
            {
                info.pszMessageText = text;
                info.pszCaptionText = caption;
                uint package = 0;
                var save = 0;
                var result = CredUIPromptForWindowsCredentialsW(&info, error, &package, null, 0, out var buffer, out var size, &save, EnumerateCurrentUser);
                if (result != 0)
                {
                    if (result != Cancelled) log?.Invoke($"trust: Windows' password prompt didn't open ({result})");
                    return false;
                }
                try
                {
                    error = Check(buffer, size, me.User);
                    if (error == 0) return true;
                }
                finally
                {
                    NativeMemory.Clear(buffer, size);
                    Marshal.FreeCoTaskMem((IntPtr)buffer);
                }
            }
        }
        log?.Invoke($"trust: the Windows password wasn't accepted ({error})");
        return false;
    }

    /// <summary>0 when the credential in <paramref name="buffer"/> signs in as <paramref name="me"/>; else the Win32 error to show in the next prompt.</summary>
    private static int Check(void* buffer, uint size, SecurityIdentifier? me)
    {
        const int Length = 514; // CREDUI_MAX_USERNAME_LENGTH + 1; a password is at most 256
        var user = (char*)NativeMemory.AllocZeroed(Length, sizeof(char));
        var domain = (char*)NativeMemory.AllocZeroed(Length, sizeof(char));
        var password = (char*)NativeMemory.AllocZeroed(Length, sizeof(char));
        try
        {
            int userLength = Length, domainLength = Length, passwordLength = Length;
            if (!CredUnPackAuthenticationBufferW(ProtectedCredentials, buffer, size, user, &userLength, domain, &domainLength, password, &passwordLength))
                return LogonFailure; // not a password (a smart card, say): asked again
            var (name, realm) = (new string(user), new string(domain));
            // The prompt answers "PC\name" or "MicrosoftAccount\address" in the name, with no domain.
            if (realm.Length == 0 && name.IndexOf('\\') is > 0 and var slash) (realm, name) = (name[..slash], name[(slash + 1)..]);
            var where = realm.Length > 0 ? realm : null;
            IntPtr token = default;
            if (!LogonUserW(name, where, password, LogonInteractive, 0, &token))
            {
                var failed = Marshal.GetLastPInvokeError();
                // An account that may not sign in at the console on this PC still proves its password over the network type.
                if (failed != LogonTypeNotGranted || !LogonUserW(name, where, password, LogonNetwork, 0, &token)) return failed == 0 ? LogonFailure : failed;
            }
            try
            {
                using var signedIn = new WindowsIdentity(token);
                return signedIn.User is { } who && me is not null && who.Equals(me) ? 0 : LogonFailure; // somebody else's password proves nothing here
            }
            finally { CloseHandle(token); }
        }
        finally
        {
            NativeMemory.Clear(password, Length * sizeof(char));
            NativeMemory.Free(user);
            NativeMemory.Free(domain);
            NativeMemory.Free(password);
        }
    }

    /// <summary>The prompt's owner: the window in front when it is ours, so the prompt opens over it; else none.</summary>
    private static IntPtr OwnForegroundWindow()
    {
        var window = GetForegroundWindow();
        return window != IntPtr.Zero && GetWindowThreadProcessId(window, out var pid) != 0 && pid == Environment.ProcessId ? window : IntPtr.Zero;
    }

    private const int EnumerateCurrentUser = 0x200, ProtectedCredentials = 0x1, Cancelled = 1223, LogonFailure = 1326, LogonTypeNotGranted = 1385, LogonInteractive = 2, LogonNetwork = 3;

    [StructLayout(LayoutKind.Sequential)]
    private struct CREDUI_INFO
    {
        public int cbSize;
        public IntPtr hwndParent;
        public char* pszMessageText;
        public char* pszCaptionText;
        public IntPtr hbmBanner;
    }

    [DllImport("credui.dll", ExactSpelling = true)]
    private static extern int CredUIPromptForWindowsCredentialsW(CREDUI_INFO* info, int authError, uint* authPackage, void* inBuffer, uint inSize, out void* outBuffer, out uint outSize, int* save, int flags);

    [DllImport("credui.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredUnPackAuthenticationBufferW(int flags, void* buffer, uint size, char* user, int* userLength, char* domain, int* domainLength, char* password, int* passwordLength);

    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LogonUserW(string user, string? domain, char* password, int type, int provider, IntPtr* token);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out int processId);
}

/// <summary>
/// What stands in for Windows Hello on a PC without it (no PIN set up): each "signature" is asked with the account's
/// Windows password, and is an HMAC under a random key this account keeps (DPAPI, in its secret store). So someone at
/// the unlocked PC still can't open the other computers with a click; unlike Hello's key, a program already running as
/// this account could read that key without asking.
/// </summary>
public sealed class PasswordSigner(ISecretStore secrets, string message, Action<string>? log = null) : IHelloSigner
{
    public const string Slot = "computers.presence";

    /// <summary>
    /// How long one typed password stands: opening the list and then a screen, or a second screen window, asks once,
    /// not each time. A password is slower than Hello's PIN or fingerprint, which still asks for every window.
    /// </summary>
    public static readonly TimeSpan Grace = TimeSpan.FromMinutes(5);

    private long _confirmedAt = -1;

    public Task<bool> IsAvailableAsync() => Task.FromResult(true);

    /// <summary>The password prompt alone, for a confirmation that seals nothing; not asked again within <see cref="Grace"/>.</summary>
    public async Task<bool> ConfirmAsync()
    {
        var last = Interlocked.Read(ref _confirmedAt);
        if (last >= 0 && TimeSpan.FromMilliseconds(Environment.TickCount64 - last) < Grace) return true;
        if (!await WindowsPassword.ConfirmAsync(message, log).ConfigureAwait(false)) return false;
        Interlocked.Exchange(ref _confirmedAt, Environment.TickCount64);
        return true;
    }

    public async Task<byte[]?> SignAsync(byte[] challenge)
    {
        if (!await ConfirmAsync().ConfigureAwait(false)) return null;
        try
        {
            byte[] key;
            if (secrets.Get(Slot) is { } kept) key = Convert.FromBase64String(kept);
            else secrets.Set(Slot, Convert.ToBase64String(key = RandomNumberGenerator.GetBytes(32)));
            return HMACSHA256.HashData(key, challenge);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException or FormatException)
        {
            log?.Invoke($"trust: the key for your computers couldn't be read ({e.GetType().Name})");
            return null;
        }
    }
}
