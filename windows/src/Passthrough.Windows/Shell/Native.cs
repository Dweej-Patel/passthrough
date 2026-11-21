using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Passthrough.Windows.Shell;

/// <summary>The Win32 calls a shell session needs. Every handle is closed by its owner.</summary>
internal static class Native
{
    public const uint ExtendedStartupInfoPresent = 0x00080000;
    public const uint CreateUnicodeEnvironment = 0x00000400;
    public const int StartfUseStdHandles = 0x00000100;
    public static readonly IntPtr ProcThreadAttributePseudoConsole = 0x00020016;
    public static readonly IntPtr ProcThreadAttributeJobList = 0x0002000D;
    public const uint JobObjectLimitKillOnJobClose = 0x00002000;
    public const int JobObjectExtendedLimitInformationClass = 9;
    public const int JobObjectBasicProcessIdList = 3;
    public const int JobObjectBasicAccountingInformation = 1;
    public const uint ProcessQueryLimitedInformation = 0x1000;
    public const uint Synchronize = 0x00100000;
    public const uint Infinite = 0xFFFFFFFF;
    public const uint StillActive = 259;
    public const uint TokenQuery = 0x0008;
    public const uint TokenDuplicate = 0x0002;
    public const int TokenElevation = 20;

    [StructLayout(LayoutKind.Sequential)]
    public struct Coord(short x, short y)
    {
        public short X = x;
        public short Y = y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct StartupInfo
    {
        public int cb;
        public IntPtr lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ProcessInformation
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }

    [StructLayout(LayoutKind.Sequential)]
    public struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JobObjectBasicAccounting
    {
        public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ProcessBasicInformation
    {
        public IntPtr ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, InheritedFromUniqueProcessId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attributes, int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);

    [DllImport("kernel32.dll")]
    public static extern void DeleteProcThreadAttributeList(IntPtr list);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateProcessW")]
    public static extern unsafe bool CreateProcess(string application, char* commandLine, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint flags, char* environment, string? directory, ref StartupInfoEx info, out ProcessInformation pi);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateJobObjectW")]
    public static extern SafeJobHandle CreateJobObject(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetInformationJobObject(SafeJobHandle job, int infoClass, ref JobObjectExtendedLimitInformation info, int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool QueryInformationJobObject(SafeJobHandle job, int infoClass, IntPtr info, int size, IntPtr returned);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool QueryInformationJobObject(SafeJobHandle job, int infoClass, out JobObjectBasicAccounting info, int size, IntPtr returned);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateJobObject(SafeJobHandle job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessTimes(SafeProcessHandle process, out long creation, out long exit, out long kernel, out long user);

    [DllImport("ntdll.dll")]
    public static extern int NtQueryInformationProcess(SafeProcessHandle process, int infoClass, out ProcessBasicInformation info, int size, out int returned);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr process, uint access, out SafeAccessTokenHandle token);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool GetTokenInformation(SafeAccessTokenHandle token, int infoClass, out int info, int size, out int returned);

    [DllImport("userenv.dll", SetLastError = true)]
    public static extern bool CreateEnvironmentBlock(out IntPtr block, SafeAccessTokenHandle token, bool inherit);

    [DllImport("userenv.dll")]
    public static extern bool DestroyEnvironmentBlock(IntPtr block);

    public static void Check(bool ok, string what)
    {
        if (!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError(), what);
    }
}

internal sealed class SafeJobHandle() : SafeHandleZeroOrMinusOneIsInvalid(ownsHandle: true)
{
    protected override bool ReleaseHandle() => Native.CloseHandle(handle);
}
