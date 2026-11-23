using System.Runtime.InteropServices;

namespace Passthrough.Windows.Net;

/// <summary>
/// The shell's DNS-SD record, <c>&lt;host&gt;._passthrough-sh._tcp.local</c>, through Windows' own API (dnsapi.dll), so
/// phones on the same network find the PC by name. The instance name is the grant's host name exactly: phones dial the
/// browse result whose name equals it. A registration Windows renames after a conflict is withdrawn (phones then dial
/// the grant's addresses). Failures never stop the listener; the service tries again.
/// </summary>
public sealed class DnsSd : IDisposable
{
    public const string ServiceType = "_passthrough-sh._tcp.local";

    private readonly Action<string>? _log;
    private readonly Lock _lock = new();
    private IntPtr _instance;
    private GCHandle _self;
    private TaskCompletionSource<(uint Status, string? Name)>? _registered;
    private static readonly RegisterCallback Callback = OnRegistered;

    public DnsSd(Action<string>? log = null) => _log = log;

    /// <summary>The name registered, once Windows confirms it.</summary>
    public string? Registered { get; private set; }

    /// <summary>Registers <paramref name="hostName"/> on <paramref name="port"/>; true when Windows confirmed that exact name.</summary>
    public async Task<bool> RegisterAsync(string hostName, int port, TimeSpan wait)
    {
        Withdraw();
        var instanceName = $"{hostName}.{ServiceType}";
        var instance = DnsServiceConstructInstance(instanceName, $"{hostName}.local", IntPtr.Zero, IntPtr.Zero, (ushort)port, 0, 0, 0, null, null);
        if (instance == IntPtr.Zero) { _log?.Invoke("dns-sd: couldn't make the record"); return false; }
        var registered = new TaskCompletionSource<(uint, string?)>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_lock)
        {
            _instance = instance;
            _registered = registered;
            if (!_self.IsAllocated) _self = GCHandle.Alloc(this);
        }
        var request = new RegisterRequest
        {
            Version = 1, // DNS_QUERY_REQUEST_VERSION1
            InterfaceIndex = 0,
            Instance = instance,
            Callback = Marshal.GetFunctionPointerForDelegate(Callback),
            Context = GCHandle.ToIntPtr(_self),
            Credentials = IntPtr.Zero,
            UnicastEnabled = false,
        };
        var status = DnsServiceRegister(ref request, IntPtr.Zero);
        if (status != DnsRequestPending)
        {
            _log?.Invoke($"dns-sd: registration refused ({status})");
            return false;
        }
        try
        {
            var (result, name) = await registered.Task.WaitAsync(wait).ConfigureAwait(false);
            if (result != 0) { _log?.Invoke($"dns-sd: registration failed ({result})"); return false; }
            if (!string.Equals(name, instanceName, StringComparison.OrdinalIgnoreCase))
            {
                // Renamed after a conflict: a phone looking for this PC's name would never match it.
                _log?.Invoke("dns-sd: Windows renamed the record after a conflict; phones find this PC by address");
                Withdraw();
                return false;
            }
            Registered = hostName;
            _log?.Invoke("dns-sd: registered");
            return true;
        }
        catch (TimeoutException)
        {
            _log?.Invoke("dns-sd: no answer from Windows' DNS-SD");
            return false;
        }
    }

    private static void OnRegistered(uint status, IntPtr context, IntPtr instance)
    {
        if (GCHandle.FromIntPtr(context).Target is not DnsSd self) return;
        string? name = null;
        if (instance != IntPtr.Zero)
        {
            name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(instance));
            DnsServiceFreeInstance(instance);
        }
        TaskCompletionSource<(uint, string?)>? registered;
        lock (self._lock) registered = self._registered;
        registered?.TrySetResult((status, name));
    }

    /// <summary>Withdraws the record (at stop, before sleep, before a name change).</summary>
    public void Withdraw()
    {
        IntPtr instance;
        lock (_lock)
        {
            instance = _instance;
            _instance = IntPtr.Zero;
        }
        Registered = null;
        if (instance == IntPtr.Zero) return;
        var request = new RegisterRequest { Version = 1, Instance = instance, Callback = Marshal.GetFunctionPointerForDelegate(Callback), Context = GCHandle.ToIntPtr(_self) };
        DnsServiceDeRegister(ref request, IntPtr.Zero);
        DnsServiceFreeInstance(instance);
    }

    public void Dispose()
    {
        Withdraw();
        if (_self.IsAllocated) _self.Free();
    }

    private const uint DnsRequestPending = 9506;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void RegisterCallback(uint status, IntPtr context, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    private struct RegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr Instance;
        public IntPtr Callback;
        public IntPtr Context;
        public IntPtr Credentials;
        [MarshalAs(UnmanagedType.Bool)] public bool UnicastEnabled;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DnsServiceConstructInstance(string serviceName, string hostName, IntPtr ip4, IntPtr ip6, ushort port, ushort priority,
        ushort weight, uint propertiesCount, string[]? keys, string[]? values);

    [DllImport("dnsapi.dll")]
    private static extern uint DnsServiceRegister(ref RegisterRequest request, IntPtr cancel);

    [DllImport("dnsapi.dll")]
    private static extern uint DnsServiceDeRegister(ref RegisterRequest request, IntPtr cancel);

    [DllImport("dnsapi.dll")]
    private static extern void DnsServiceFreeInstance(IntPtr instance);
}
