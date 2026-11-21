using System.ComponentModel;
using System.Runtime.InteropServices;
using Passthrough.Core.Setup;

namespace Passthrough.Windows.Setup;

/// <summary>
/// The Service Control Manager for Passthrough's service, with section 2's values: own process, automatic start, the
/// virtual account, a restricted service SID, only the change-notify privilege, two restarts after a crash, a 5 s
/// pre-shutdown, and the service's own security.
/// </summary>
public sealed class WindowsServiceControl : IServiceControl
{
    private readonly string _name;

    public WindowsServiceControl(string name = ServiceDefinition.Name) => _name = name;

    public ServiceConfig? Query()
    {
        using var manager = Manager(Native.ScManagerConnect);
        using var service = Open(manager, Native.ServiceQueryConfig, required: false);
        if (service is null) return null;
        Native.QueryServiceConfig(service.Handle, IntPtr.Zero, 0, out var needed);
        var buffer = Marshal.AllocHGlobal(needed);
        try
        {
            if (!Native.QueryServiceConfig(service.Handle, buffer, needed, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryServiceConfig");
            var config = Marshal.PtrToStructure<Native.QueryServiceConfigW>(buffer);
            var start = config.StartType switch { Native.ServiceAutoStart => ServiceStart.Automatic, Native.ServiceDisabled => ServiceStart.Disabled, _ => ServiceStart.Manual };
            return new ServiceConfig(Marshal.PtrToStringUni(config.BinaryPathName) ?? "", start);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public bool IsRunning() => State() is { } state && state != Native.ServiceStopped;

    /// <summary>The service's state (SERVICE_RUNNING and so on) and process id; null when it isn't installed.</summary>
    public (uint State, uint ProcessId, uint ExitCode)? Status()
    {
        using var manager = Manager(Native.ScManagerConnect);
        using var service = Open(manager, Native.ServiceQueryStatus, required: false);
        if (service is null) return null;
        var status = new Native.ServiceStatusProcess();
        if (!Native.QueryServiceStatusEx(service.Handle, 0, ref status, Marshal.SizeOf<Native.ServiceStatusProcess>(), out _))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryServiceStatusEx");
        return (status.CurrentState, status.ProcessId, status.Win32ExitCode == Native.ErrorServiceSpecific ? status.ServiceSpecificExitCode : status.Win32ExitCode);
    }

    private uint? State() => Status()?.State;

    public void Configure(string binaryPath, ServiceStart start, IReadOnlyList<string> allowedAccounts)
    {
        using var manager = Manager(Native.ScManagerConnect | Native.ScManagerCreateService);
        var service = Open(manager, Native.ServiceAllAccess, required: false);
        if (service is null)
        {
            var handle = Native.CreateService(manager.Handle, _name, ServiceDefinition.DisplayName, Native.ServiceAllAccess, Native.ServiceWin32OwnProcess,
                StartType(start), Native.ServiceErrorNormal, binaryPath, null, IntPtr.Zero, "Tcpip\0KeyIso\0\0", ServiceDefinition.Account, null);
            if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateService");
            service = new ServiceHandle(handle);
        }
        else if (!Native.ChangeServiceConfig(service.Handle, Native.ServiceWin32OwnProcess, StartType(start), Native.ServiceErrorNormal, binaryPath, null,
                     IntPtr.Zero, "Tcpip\0KeyIso\0\0", ServiceDefinition.Account, null, ServiceDefinition.DisplayName))
        {
            service.Dispose();
            throw new Win32Exception(Marshal.GetLastWin32Error(), "ChangeServiceConfig");
        }
        using (service)
        {
            ConfigureExtras(service);
            ApplySecurity(service, allowedAccounts);
        }
    }

    private static void ConfigureExtras(ServiceHandle service)
    {
        var description = new Native.ServiceDescription { Description = ServiceDefinition.Description };
        Config2(service, Native.ServiceConfigDescription, description);
        Config2(service, Native.ServiceConfigServiceSidInfo, new Native.ServiceSidInfo { SidType = Native.ServiceSidTypeRestricted });
        Config2(service, Native.ServiceConfigRequiredPrivilegesInfo, new Native.ServiceRequiredPrivilegesInfo { Privileges = "SeChangeNotifyPrivilege\0\0" });
        Config2(service, Native.ServiceConfigPreshutdownInfo, new Native.ServicePreshutdownInfo { Timeout = 5000 });
        // Two restarts after a crash (5 s, then 30 s), then none; the count resets after a day.
        var actions = new[] { new Native.ScAction { Type = 1, Delay = 5000 }, new Native.ScAction { Type = 1, Delay = 30000 }, new Native.ScAction { Type = 0, Delay = 0 } };
        var size = Marshal.SizeOf<Native.ScAction>();
        var array = Marshal.AllocHGlobal(size * actions.Length);
        try
        {
            for (var i = 0; i < actions.Length; i++) Marshal.StructureToPtr(actions[i], array + i * size, false);
            Config2(service, Native.ServiceConfigFailureActions, new Native.ServiceFailureActions { ResetPeriod = 86400, ActionCount = (uint)actions.Length, Actions = array });
        }
        finally { Marshal.FreeHGlobal(array); }
        Config2(service, Native.ServiceConfigFailureActionsFlag, new Native.ServiceFailureActionsFlag { FailureActionsOnNonCrashFailures = false });
    }

    private static void Config2<T>(ServiceHandle service, uint level, T info) where T : struct
    {
        var buffer = Marshal.AllocHGlobal(Marshal.SizeOf<T>());
        try
        {
            Marshal.StructureToPtr(info, buffer, false);
            if (!Native.ChangeServiceConfig2(service.Handle, level, buffer)) throw new Win32Exception(Marshal.GetLastWin32Error(), $"ChangeServiceConfig2({level})");
        }
        finally
        {
            Marshal.DestroyStructure<T>(buffer);
            Marshal.FreeHGlobal(buffer);
        }
    }

    public void SetStartType(ServiceStart start)
    {
        using var manager = Manager(Native.ScManagerConnect);
        using var service = Open(manager, Native.ServiceChangeConfig, required: true)!;
        if (!Native.ChangeServiceConfig(service.Handle, Native.ServiceNoChange, StartType(start), Native.ServiceNoChange, null, null, IntPtr.Zero, null, null, null, null))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "ChangeServiceConfig");
    }

    public void SetSecurity(IReadOnlyList<string> allowedAccounts)
    {
        using var manager = Manager(Native.ScManagerConnect);
        using var service = Open(manager, Native.WriteDac | Native.ReadControl, required: true)!;
        ApplySecurity(service, allowedAccounts);
    }

    private static void ApplySecurity(ServiceHandle service, IReadOnlyList<string> allowedAccounts)
    {
        if (!Native.ConvertStringSecurityDescriptorToSecurityDescriptor(ServiceDefinition.ServiceSddl(allowedAccounts), 1, out var descriptor, out _))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "ConvertStringSecurityDescriptorToSecurityDescriptor");
        try
        {
            if (!Native.SetServiceObjectSecurity(service.Handle, Native.DaclSecurityInformation, descriptor))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetServiceObjectSecurity");
        }
        finally { Native.LocalFree(descriptor); }
    }

    public void Delete()
    {
        using var manager = Manager(Native.ScManagerConnect);
        using var service = Open(manager, Native.Delete, required: false);
        if (service is null) return;
        if (!Native.DeleteService(service.Handle) && Marshal.GetLastWin32Error() != Native.ErrorServiceMarkedForDelete)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "DeleteService");
    }

    public void Start(TimeSpan wait)
    {
        using (var manager = Manager(Native.ScManagerConnect))
        using (var service = Open(manager, Native.ServiceStart, required: true)!)
        {
            if (!Native.StartService(service.Handle, 0, IntPtr.Zero) && Marshal.GetLastWin32Error() is var error && error != Native.ErrorServiceAlreadyRunning)
                throw new SetupException(error == Native.ErrorServiceLogonFailed ? "Windows wouldn't sign the service in (1069)." : $"The service didn't start ({error}).");
        }
        var deadline = DateTime.UtcNow + wait;
        while (DateTime.UtcNow < deadline)
        {
            var status = Status();
            if (status?.State == Native.ServiceRunning) return;
            if (status?.State == Native.ServiceStopped) throw new SetupException($"The service stopped as it started (exit code {status.Value.ExitCode}). See the service's log.");
            Thread.Sleep(200);
        }
        throw new SetupException("The service didn't finish starting in time.");
    }

    public void Stop(TimeSpan wait)
    {
        using (var manager = Manager(Native.ScManagerConnect))
        using (var service = Open(manager, Native.ServiceStop | Native.ServiceQueryStatus, required: false))
        {
            if (service is null) return;
            var status = new Native.ServiceStatus();
            if (!Native.ControlService(service.Handle, Native.ServiceControlStop, ref status)
                && Marshal.GetLastWin32Error() is var error && error is not (Native.ErrorServiceNotActive or Native.ErrorServiceCannotAcceptCtrl))
                throw new Win32Exception(error, "ControlService(stop)");
        }
        var deadline = DateTime.UtcNow + wait;
        while (DateTime.UtcNow < deadline)
        {
            if (State() is null or Native.ServiceStopped) return;
            Thread.Sleep(200);
        }
        throw new SetupException("The service didn't stop in time.");
    }

    public bool SendControl(int code)
    {
        using var manager = Manager(Native.ScManagerConnect);
        using var service = Open(manager, Native.ServiceUserDefinedControl, required: false);
        if (service is null) return false;
        var status = new Native.ServiceStatus();
        return Native.ControlService(service.Handle, (uint)code, ref status);
    }

    /// <summary>Starts the service as an allowed account may (no prompt: its security lets them start it, never stop it).</summary>
    public static bool TryStart(string name = ServiceDefinition.Name)
    {
        var manager = Native.OpenSCManager(null, null, Native.ScManagerConnect);
        if (manager == IntPtr.Zero) return false;
        try
        {
            var service = Native.OpenService(manager, name, Native.ServiceStart);
            if (service == IntPtr.Zero) return false;
            try { return Native.StartService(service, 0, IntPtr.Zero) || Marshal.GetLastWin32Error() == Native.ErrorServiceAlreadyRunning; }
            finally { Native.CloseServiceHandle(service); }
        }
        finally { Native.CloseServiceHandle(manager); }
    }

    public bool DeleteProfile()
    {
        // The virtual account's profile: its folder (the TLS key, DPAPI's keys) and its ProfileList entry.
        if (!Native.DeleteProfile(ServiceDefinition.Sid, null, null))
        {
            var error = Marshal.GetLastWin32Error();
            if (error is Native.ErrorFileNotFound or Native.ErrorPathNotFound or Native.ErrorNoSuchUser or Native.ErrorInvalidParameter) return false;
            throw new Win32Exception(error, "DeleteProfile");
        }
        return true;
    }

    private static uint StartType(ServiceStart start) => start switch
    {
        ServiceStart.Automatic => Native.ServiceAutoStart,
        ServiceStart.Disabled => Native.ServiceDisabled,
        _ => Native.ServiceDemandStart,
    };

    private static ServiceHandle Manager(uint access)
    {
        var handle = Native.OpenSCManager(null, null, access);
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManager");
        return new ServiceHandle(handle);
    }

    private ServiceHandle? Open(ServiceHandle manager, uint access, bool required)
    {
        var handle = Native.OpenService(manager.Handle, _name, access);
        if (handle != IntPtr.Zero) return new ServiceHandle(handle);
        var error = Marshal.GetLastWin32Error();
        if (error == Native.ErrorServiceDoesNotExist && !required) return null;
        if (error == Native.ErrorServiceDoesNotExist) throw new SetupException("Remote access isn't set up on this PC.");
        throw new Win32Exception(error, "OpenService");
    }

    private sealed class ServiceHandle(IntPtr handle) : IDisposable
    {
        public IntPtr Handle { get; } = handle;
        public void Dispose() => Native.CloseServiceHandle(Handle);
    }

    internal static class Native
    {
        public const uint ScManagerConnect = 0x0001, ScManagerCreateService = 0x0002;
        public const uint ServiceQueryConfig = 0x0001, ServiceChangeConfig = 0x0002, ServiceQueryStatus = 0x0004, ServiceStart = 0x0010,
            ServiceStop = 0x0020, ServiceUserDefinedControl = 0x0100, ServiceAllAccess = 0xF01FF, Delete = 0x10000, ReadControl = 0x20000, WriteDac = 0x40000;
        public const uint ServiceWin32OwnProcess = 0x10, ServiceAutoStart = 2, ServiceDemandStart = 3, ServiceDisabled = 4, ServiceErrorNormal = 1, ServiceNoChange = 0xFFFFFFFF;
        public const uint ServiceStopped = 1, ServiceRunning = 4, ServiceControlStop = 1;
        public const uint ServiceConfigDescription = 1, ServiceConfigFailureActions = 2, ServiceConfigFailureActionsFlag = 4, ServiceConfigServiceSidInfo = 5,
            ServiceConfigRequiredPrivilegesInfo = 6, ServiceConfigPreshutdownInfo = 7;
        public const uint ServiceSidTypeRestricted = 3, DaclSecurityInformation = 4;
        public const int ErrorFileNotFound = 2, ErrorPathNotFound = 3, ErrorInvalidParameter = 87, ErrorServiceSpecific = 1066, ErrorServiceAlreadyRunning = 1056,
            ErrorServiceDoesNotExist = 1060, ErrorServiceCannotAcceptCtrl = 1061, ErrorServiceNotActive = 1062, ErrorServiceLogonFailed = 1069,
            ErrorServiceMarkedForDelete = 1072, ErrorNoSuchUser = 1317;

        [StructLayout(LayoutKind.Sequential)]
        public struct ServiceStatus { public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint; }

        [StructLayout(LayoutKind.Sequential)]
        public struct ServiceStatusProcess
        {
            public uint ServiceType, CurrentState, ControlsAccepted;
            public uint Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint, ProcessId, ServiceFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct QueryServiceConfigW
        {
            public uint ServiceType, StartType, ErrorControl;
            public IntPtr BinaryPathName, LoadOrderGroup;
            public uint TagId;
            public IntPtr Dependencies, ServiceStartName, DisplayName;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct ServiceDescription { public string Description; }

        [StructLayout(LayoutKind.Sequential)]
        public struct ServiceSidInfo { public uint SidType; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct ServiceRequiredPrivilegesInfo { public string Privileges; }

        [StructLayout(LayoutKind.Sequential)]
        public struct ServicePreshutdownInfo { public uint Timeout; }

        [StructLayout(LayoutKind.Sequential)]
        public struct ScAction { public uint Type, Delay; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct ServiceFailureActions
        {
            public uint ResetPeriod;
            public string? RebootMessage;
            public string? Command;
            public uint ActionCount;
            public IntPtr Actions;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct ServiceFailureActionsFlag { [MarshalAs(UnmanagedType.Bool)] public bool FailureActionsOnNonCrashFailures; }

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "OpenSCManagerW")]
        public static extern IntPtr OpenSCManager(string? machine, string? database, uint access);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "OpenServiceW")]
        public static extern IntPtr OpenService(IntPtr manager, string name, uint access);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateServiceW")]
        public static extern IntPtr CreateService(IntPtr manager, string name, string displayName, uint access, uint serviceType, uint startType, uint errorControl,
            string binaryPath, string? loadOrderGroup, IntPtr tagId, string? dependencies, string? account, string? password);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "ChangeServiceConfigW")]
        public static extern bool ChangeServiceConfig(IntPtr service, uint serviceType, uint startType, uint errorControl, string? binaryPath, string? loadOrderGroup,
            IntPtr tagId, string? dependencies, string? account, string? password, string? displayName);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "ChangeServiceConfig2W")]
        public static extern bool ChangeServiceConfig2(IntPtr service, uint infoLevel, IntPtr info);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "QueryServiceConfigW")]
        public static extern bool QueryServiceConfig(IntPtr service, IntPtr config, int size, out int needed);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool QueryServiceStatusEx(IntPtr service, int infoLevel, ref ServiceStatusProcess status, int size, out int needed);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool StartService(IntPtr service, int argc, IntPtr argv);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool ControlService(IntPtr service, uint control, ref ServiceStatus status);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool DeleteService(IntPtr service);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool SetServiceObjectSecurity(IntPtr service, uint securityInformation, IntPtr descriptor);

        [DllImport("advapi32.dll")]
        public static extern bool CloseServiceHandle(IntPtr handle);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW")]
        public static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, uint revision, out IntPtr descriptor, out uint size);

        [DllImport("kernel32.dll")]
        public static extern IntPtr LocalFree(IntPtr memory);

        [DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "DeleteProfileW")]
        public static extern bool DeleteProfile(string sid, string? profilePath, string? computerName);
    }
}
