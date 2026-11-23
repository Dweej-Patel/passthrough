using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Passthrough.Windows.Power;

/// <summary>
/// A power request (PowerCreateRequest): while set, the idle timer doesn't put the PC to sleep. Never the display's.
/// It shows in <c>powercfg /requests</c> under the service with its reason. It can't stop a sleep someone chose (the
/// Start menu, the lid), hibernation at low battery, or a Modern Standby PC on battery.
/// </summary>
public sealed class PowerRequest : IDisposable
{
    private readonly SafeFileHandle _handle;
    private bool _set;

    public PowerRequest(string reason)
    {
        var context = new ReasonContext { Version = 0, Flags = 0x1 /* POWER_REQUEST_CONTEXT_SIMPLE_STRING */, Reason = reason };
        _handle = PowerCreateRequest(ref context);
        if (_handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "PowerCreateRequest");
    }

    public bool IsSet => _set;

    public void Set(bool on)
    {
        if (on == _set) return;
        var ok = on ? PowerSetRequest(_handle, SystemRequired) : PowerClearRequest(_handle, SystemRequired);
        if (ok) _set = on;
    }

    public void Dispose()
    {
        Set(false);
        _handle.Dispose();
    }

    private const int SystemRequired = 1; // PowerRequestSystemRequired

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ReasonContext
    {
        public uint Version;
        public uint Flags;
        public string Reason;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle PowerCreateRequest(ref ReasonContext context);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool PowerSetRequest(SafeFileHandle handle, int type);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool PowerClearRequest(SafeFileHandle handle, int type);
}

/// <summary>What the PC's power says: on mains, a battery, and its sleep timer for the current source.</summary>
public static class PowerFacts
{
    /// <summary>On mains power (or unknown: a desktop).</summary>
    public static bool OnMains => !GetSystemPowerStatus(out var status) || status.ACLineStatus != 0;

    public static bool HasBattery => GetSystemPowerStatus(out var status) && (status.BatteryFlag & 128) == 0 && status.BatteryFlag != 255;

    /// <summary>The active plan's sleep-after for the current power source, in seconds (0: never); null when it can't be read.</summary>
    public static int? SleepAfterSeconds()
    {
        if (PowerGetActiveScheme(IntPtr.Zero, out var scheme) != 0) return null;
        try
        {
            var subgroup = SleepSubgroup;
            var setting = StandbyIdle;
            var guid = Marshal.PtrToStructure<Guid>(scheme);
            var result = OnMains
                ? PowerReadACValueIndex(IntPtr.Zero, ref guid, ref subgroup, ref setting, out var value)
                : PowerReadDCValueIndex(IntPtr.Zero, ref guid, ref subgroup, ref setting, out value);
            return result == 0 ? (int)value : null;
        }
        finally { LocalFree(scheme); }
    }

    private static readonly Guid SleepSubgroup = new("238c9fa8-0aad-41ed-83f4-97be242c8f20");
    private static readonly Guid StandbyIdle = new("29f6c1db-86da-48c5-9fdb-f2b67b1f44da");

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public int BatteryLifeTime, BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")]
    private static extern bool GetSystemPowerStatus(out SystemPowerStatus status);

    [DllImport("powrprof.dll")]
    private static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);

    [DllImport("powrprof.dll")]
    private static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);

    [DllImport("powrprof.dll")]
    private static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
