using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace Passthrough.Windows.Pipes;

/// <summary>
/// Named pipes with every flag explicit (not the .NET helpers): first instance only, remote clients refused, a given
/// security descriptor; and the reads either end needs about the other (who serves it, who owns it).
/// </summary>
public static class PipeNative
{
    public const uint PipeAccessDuplex = 0x3, FileFlagOverlapped = 0x40000000, FileFlagFirstPipeInstance = 0x00080000;
    public const uint PipeTypeByte = 0, PipeReadModeByte = 0, PipeWait = 0, PipeRejectRemoteClients = 0x8;
    public const uint SecuritySqosPresent = 0x00100000, SecurityAnonymous = 0, SecurityIdentification = 0x00010000;
    public const uint FileReadData = 0x1, FileWriteData = 0x2, FileReadAttributes = 0x80, ReadControl = 0x20000, Synchronize = 0x100000;
    public const int ErrorFileNotFound = 2, ErrorAccessDenied = 5, ErrorPipeBusy = 231;

    /// <summary>
    /// Creates <c>\\.\pipe\<paramref name="name"/></c> with <paramref name="sddl"/> as its security. With
    /// <paramref name="first"/> it fails if anyone already has the name: a pipe's security is its first instance's.
    /// </summary>
    public static NamedPipeServerStream CreateServer(string name, string sddl, bool first, int maxInstances, int bufferSize = 65536)
    {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out var descriptor, out _))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "ConvertStringSecurityDescriptorToSecurityDescriptor");
        try
        {
            var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = descriptor };
            var handle = CreateNamedPipe(@"\\.\pipe\" + name, PipeAccessDuplex | FileFlagOverlapped | (first ? FileFlagFirstPipeInstance : 0),
                PipeTypeByte | PipeReadModeByte | PipeWait | PipeRejectRemoteClients, (uint)maxInstances, (uint)bufferSize, (uint)bufferSize, 0, ref attributes);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateNamedPipe");
            return new NamedPipeServerStream(PipeDirection.InOut, isAsync: true, isConnected: false, handle);
        }
        finally { LocalFree(descriptor); }
    }

    /// <summary>
    /// Opens a pipe as a client. <paramref name="anonymous"/>: the server may not use this client's identity at all
    /// (the elevated end of the setup pipe); otherwise identification only (it can read who we are, never act as us).
    /// Asks only for read, write, attributes and read-control: never the right to create an instance.
    /// </summary>
    public static NamedPipeClientStream OpenClient(string name, bool anonymous)
    {
        var handle = CreateFile(@"\\.\pipe\" + name, FileReadData | FileWriteData | FileReadAttributes | ReadControl | Synchronize, 0, IntPtr.Zero, 3 /* OPEN_EXISTING */,
            FileFlagOverlapped | SecuritySqosPresent | (anonymous ? SecurityAnonymous : SecurityIdentification), IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFile(pipe)");
        return new NamedPipeClientStream(PipeDirection.InOut, isAsync: true, isConnected: true, handle);
    }

    public static int ServerProcessId(SafePipeHandle pipe) =>
        GetNamedPipeServerProcessId(pipe, out var pid) ? (int)pid : throw new Win32Exception(Marshal.GetLastWin32Error(), "GetNamedPipeServerProcessId");

    public static int ClientProcessId(SafePipeHandle pipe) =>
        GetNamedPipeClientProcessId(pipe, out var pid) ? (int)pid : throw new Win32Exception(Marshal.GetLastWin32Error(), "GetNamedPipeClientProcessId");

    /// <summary>The owner of the pipe object (its first instance's creator).</summary>
    public static SecurityIdentifier Owner(SafePipeHandle pipe)
    {
        var error = GetSecurityInfo(pipe, 6 /* SE_KERNEL_OBJECT */, 1 /* OWNER_SECURITY_INFORMATION */, out var owner, out _, out _, out _, out var descriptor);
        if (error != 0) throw new Win32Exception((int)error, "GetSecurityInfo");
        try { return new SecurityIdentifier(owner); }
        finally { LocalFree(descriptor); }
    }

    /// <summary>The account and Windows session of a process; null when it can't be read.</summary>
    public static (SecurityIdentifier User, int Session)? ProcessAccount(int pid)
    {
        using var process = OpenProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, false, pid);
        if (process.IsInvalid || !OpenProcessToken(process, 0x8 /* TOKEN_QUERY */, out var token)) return null;
        using (token)
        {
            if (!ProcessIdToSessionId(pid, out var session)) return null;
            using var identity = new WindowsIdentity(token.DangerousGetHandle());
            return identity.User is { } user ? (user, (int)session) : null;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public IntPtr Descriptor;
        public int InheritHandle;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateNamedPipeW")]
    private static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode, uint maxInstances, uint outBuffer, uint inBuffer, uint timeout,
        ref SecurityAttributes attributes);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateFileW")]
    private static extern SafePipeHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);

    [DllImport("advapi32.dll")]
    private static extern uint GetSecurityInfo(SafeHandle handle, int objectType, uint info, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl,
        out IntPtr descriptor);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW")]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, uint revision, out IntPtr descriptor, out uint size);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int pid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ProcessIdToSessionId(int pid, out uint session);
}
