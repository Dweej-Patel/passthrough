using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
using Passthrough.Core.Pipe;
using Passthrough.Core.Setup;
using Passthrough.Windows.Setup;

namespace Passthrough.Windows.Pipes;

/// <summary>
/// <c>\\.\pipe\PassthroughService</c> (stage 4 plan, section 4). The service makes it first, owned by its own SID, with
/// remote clients refused twice (the flag and a deny entry for network logons) and a mask that never includes the
/// right to create an instance, so no client can add one. The tray app checks, before sending anything, that the pipe's
/// owner is the service's SID and its server the service's process, so a program that took the name while the service
/// was down learns nothing.
/// </summary>
public static class ServicePipe
{
    public const int MaxInstances = 8;

    /// <summary>The pipe's security: the service and SYSTEM full; interactive users read, write and attributes only.</summary>
    public static string Sddl(string serviceSid) => $"O:{serviceSid}D:P(D;;GA;;;NU)(A;;GA;;;{serviceSid})(A;;GA;;;SY)(A;;0x12019b;;;IU)";

    /// <summary>One instance of the pipe for a tray app to connect to (the service's side). <paramref name="first"/>: fail if anyone else holds the name.</summary>
    public static NamedPipeServerStream CreateInstance(bool first, string name = PipeProtocol.Name, string? serviceSid = null) =>
        PipeNative.CreateServer(name, Sddl(serviceSid ?? ServiceDefinition.Sid), first, MaxInstances);

    /// <summary>
    /// Who connected (the service's side), from the client's token at identification level: its account, session,
    /// elevation and integrity. Null when it can't be read (then it is refused).
    /// </summary>
    public static PipePeer? Peer(NamedPipeServerStream pipe)
    {
        if (!ImpersonateNamedPipeClient(pipe.SafePipeHandle)) return null;
        SafeAccessTokenHandle? token = null;
        try
        {
            // As the client first (its own token lets it); then as this process.
            if (!OpenThreadToken(GetCurrentThread(), TokenQuery, false, out token) && !OpenThreadToken(GetCurrentThread(), TokenQuery, true, out token)) return null;
        }
        finally
        {
            if (!RevertToSelf()) Environment.FailFast("RevertToSelf failed after reading a pipe client's token.");
        }
        using (token)
            return FromToken(token);
    }

    internal static PipePeer? FromToken(SafeAccessTokenHandle token)
    {
        using var identity = new WindowsIdentity(token.DangerousGetHandle());
        if (identity.User is not { } user) return null;
        if (!GetTokenInformation(token, TokenSessionId, out int session, sizeof(int), out _)) return null;
        var elevated = GetTokenInformation(token, TokenElevation, out int elevation, sizeof(int), out _) && elevation != 0;
        return new PipePeer(user.Value, session, elevated, IntegrityOf(token));
    }

    private static PipePeer.Integrity IntegrityOf(SafeAccessTokenHandle token)
    {
        GetTokenInformation(token, TokenIntegrityLevel, IntPtr.Zero, 0, out var needed);
        if (needed <= 0) return PipePeer.Integrity.Untrusted;
        var buffer = Marshal.AllocHGlobal(needed);
        try
        {
            if (!GetTokenInformation(token, TokenIntegrityLevel, buffer, needed, out _)) return PipePeer.Integrity.Untrusted;
            var sid = new SecurityIdentifier(Marshal.ReadIntPtr(buffer));
            // S-1-16-<rid>: 0x1000 low, 0x2000 medium, 0x2100 medium plus, 0x3000 high, 0x4000 system.
            var rid = int.Parse(sid.Value.Split('-')[^1], System.Globalization.CultureInfo.InvariantCulture);
            return rid switch
            {
                >= 0x4000 => PipePeer.Integrity.System,
                >= 0x3000 => PipePeer.Integrity.High,
                >= 0x2000 => PipePeer.Integrity.Medium,
                >= 0x1000 => PipePeer.Integrity.Low,
                _ => PipePeer.Integrity.Untrusted,
            };
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    /// <summary>The service isn't running, or isn't answering yet: try again later.</summary>
    public sealed class NotThereException(string message) : IOException(message);

    /// <summary>Something else holds the service's pipe name.</summary>
    public sealed class ImpostorException(string message) : IOException(message);

    /// <summary>
    /// Opens the service's pipe (the tray app's side) at identification level, then checks it is the service's
    /// before anything is sent: owned by the service's SID, served by the service's running process.
    /// </summary>
    public static NamedPipeClientStream Connect(string name = PipeProtocol.Name, string? serviceSid = null, Func<int?>? servicePid = null)
    {
        NamedPipeClientStream pipe;
        try { pipe = PipeNative.OpenClient(name, anonymous: false); }
        catch (Win32Exception e) when (e.NativeErrorCode is PipeNative.ErrorFileNotFound or PipeNative.ErrorPipeBusy)
        {
            throw new NotThereException(e.NativeErrorCode == PipeNative.ErrorPipeBusy ? "The service is busy." : "The service isn't running.");
        }
        try
        {
            var owner = PipeNative.Owner(pipe.SafePipeHandle);
            if (owner.Value != (serviceSid ?? ServiceDefinition.Sid)) throw new ImpostorException("The pipe isn't the service's (wrong owner).");
            var expected = (servicePid ?? ServicePid)();
            if (expected is null || PipeNative.ServerProcessId(pipe.SafePipeHandle) != expected) throw new ImpostorException("The pipe isn't the service's (wrong process).");
            return pipe;
        }
        catch
        {
            pipe.Dispose();
            throw;
        }
    }

    private static int? ServicePid() =>
        new WindowsServiceControl().Status() is { State: 4 /* running */, ProcessId: var pid and > 0 } ? (int)pid : null;

    private const uint TokenQuery = 0x0008;
    private const int TokenElevation = 20, TokenIntegrityLevel = 25, TokenSessionId = 12;

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool ImpersonateNamedPipeClient(SafePipeHandle pipe);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool RevertToSelf();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentThread();

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenThreadToken(IntPtr thread, uint access, bool openAsSelf, out SafeAccessTokenHandle token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int infoClass, out int info, int length, out int returned);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int infoClass, IntPtr info, int length, out int returned);
}
