using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Passthrough.Windows.Service;

/// <summary>A control the Service Control Manager sent, as the service sees it.</summary>
public enum ServiceControl
{
    Stop,
    /// <summary>Windows is shutting down; the service has its pre-shutdown time to say so.</summary>
    PreShutdown,
    /// <summary>A power event: <see cref="ServiceControlEvent.EventType"/> is PBT_APMSUSPEND (4), PBT_APMRESUMEAUTOMATIC (18), PBT_APMPOWERSTATUSCHANGE (10)…</summary>
    PowerEvent,
    /// <summary>A Windows session changed: <see cref="ServiceControlEvent.EventType"/> is WTS_SESSION_LOGON (5), WTS_SESSION_LOGOFF (6)…; <see cref="ServiceControlEvent.Session"/> its id.</summary>
    SessionChange,
    /// <summary>A user-defined control (128 to 255): <see cref="ServiceControlEvent.Code"/>.</summary>
    UserDefined,
}

public readonly record struct ServiceControlEvent(ServiceControl Control, int Code, int EventType, int Session);

/// <summary>
/// The service's own host over <c>StartServiceCtrlDispatcher</c> and <c>RegisterServiceCtrlHandlerEx</c> (not
/// ServiceBase, which never delivers pre-shutdown). <see cref="Run"/> blocks the calling thread for the service's
/// life. The body runs until it returns; controls go to <paramref name="onControl"/> on the dispatcher's thread, which
/// blocks Windows only as long as the handler does (suspend and pre-shutdown use that on purpose).
/// </summary>
public static class ServiceHost
{
    private const uint ServiceWin32OwnProcess = 0x10, StartPending = 2, Running = 4, StopPending = 3, Stopped = 1;
    private const uint AcceptStop = 0x1, AcceptPowerEvent = 0x40, AcceptSessionChange = 0x80, AcceptPreShutdown = 0x100;
    private const uint ControlStop = 1, ControlInterrogate = 4, ControlPowerEvent = 13, ControlSessionChange = 14, ControlPreShutdown = 15;
    private const int NoError = 0, ErrorCallNotImplemented = 120, ErrorServiceSpecific = 1066;

    private static ServiceMainCallback? _main;
    private static HandlerEx? _handler;
    private static IntPtr _status;
    private static string _name = "";
    private static Func<CancellationToken, Task<int>>? _body;
    private static Func<ServiceControlEvent, bool>? _onControl;
    private static readonly CancellationTokenSource Stopping = new();
    private static int _exitCode;

    /// <summary>
    /// Runs the service: <paramref name="body"/> until it returns (its result is the service-specific exit code, 0 for
    /// none), cancelled at a stop. <paramref name="onControl"/> returns whether it handled the control. False when not
    /// started by the Service Control Manager.
    /// </summary>
    public static bool Run(string name, Func<CancellationToken, Task<int>> body, Func<ServiceControlEvent, bool> onControl)
    {
        _name = name;
        _body = body;
        _onControl = onControl;
        _main = ServiceMain;
        _handler = Handler;
        var table = new[] { new ServiceTableEntry { Name = name, Proc = Marshal.GetFunctionPointerForDelegate(_main) }, default };
        if (StartServiceCtrlDispatcher(table)) return true;
        var error = Marshal.GetLastWin32Error();
        if (error == 1063) return false; // ERROR_FAILED_SERVICE_CONTROLLER_CONNECT: run from a console
        throw new Win32Exception(error, "StartServiceCtrlDispatcher");
    }

    /// <summary>Cancels the body (the service is stopping for a reason of its own).</summary>
    public static void RequestStop() => Stopping.Cancel();

    private static void ServiceMain(int argc, IntPtr argv)
    {
        _status = RegisterServiceCtrlHandlerEx(_name, _handler!, IntPtr.Zero);
        if (_status == IntPtr.Zero) return;
        Report(StartPending, 0, waitHint: 10000);
        int code;
        try
        {
            var task = _body!(Stopping.Token);
            Report(Running, AcceptStop | AcceptPreShutdown | AcceptPowerEvent | AcceptSessionChange);
            code = task.GetAwaiter().GetResult();
        }
        catch (OperationCanceledException) { code = 0; }
        catch (Exception)
        {
            code = 1; // a crash: Windows' recovery restarts it (twice a day at most)
            Interlocked.Exchange(ref _exitCode, code);
            Report(Stopped, 0, exitCode: code);
            Environment.Exit(1);
            return;
        }
        Report(Stopped, 0, exitCode: code);
    }

    private static int Handler(uint control, uint eventType, IntPtr eventData, IntPtr context)
    {
        switch (control)
        {
            case ControlStop:
                Report(StopPending, 0, waitHint: 5000);
                _onControl?.Invoke(new ServiceControlEvent(ServiceControl.Stop, (int)control, 0, 0));
                Stopping.Cancel();
                return NoError;
            case ControlPreShutdown:
                Report(StopPending, 0, waitHint: 5000);
                _onControl?.Invoke(new ServiceControlEvent(ServiceControl.PreShutdown, (int)control, 0, 0));
                Stopping.Cancel();
                return NoError;
            case ControlPowerEvent:
                _onControl?.Invoke(new ServiceControlEvent(ServiceControl.PowerEvent, (int)control, (int)eventType, 0));
                return NoError;
            case ControlSessionChange:
                // WTSSESSION_NOTIFICATION { DWORD cbSize; DWORD dwSessionId; }
                var session = eventData == IntPtr.Zero ? -1 : Marshal.ReadInt32(eventData, 4);
                _onControl?.Invoke(new ServiceControlEvent(ServiceControl.SessionChange, (int)control, (int)eventType, session));
                return NoError;
            case ControlInterrogate:
                return NoError;
            case >= 128 and <= 255:
                return _onControl?.Invoke(new ServiceControlEvent(ServiceControl.UserDefined, (int)control, 0, 0)) == true ? NoError : ErrorCallNotImplemented;
            default:
                return ErrorCallNotImplemented;
        }
    }

    private static uint _checkPoint;

    private static void Report(uint state, uint accepted, int exitCode = 0, uint waitHint = 0)
    {
        var status = new ServiceStatus
        {
            ServiceType = ServiceWin32OwnProcess,
            CurrentState = state,
            ControlsAccepted = accepted,
            Win32ExitCode = exitCode == 0 ? 0u : ErrorServiceSpecific,
            ServiceSpecificExitCode = (uint)exitCode,
            CheckPoint = state is StartPending or StopPending ? ++_checkPoint : 0,
            WaitHint = waitHint,
        };
        SetServiceStatus(_status, ref status);
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void ServiceMainCallback(int argc, IntPtr argv);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int HandlerEx(uint control, uint eventType, IntPtr eventData, IntPtr context);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ServiceTableEntry
    {
        public string? Name;
        public IntPtr Proc;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatus { public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint; }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "StartServiceCtrlDispatcherW")]
    private static extern bool StartServiceCtrlDispatcher([In] ServiceTableEntry[] table);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "RegisterServiceCtrlHandlerExW")]
    private static extern IntPtr RegisterServiceCtrlHandlerEx(string name, HandlerEx handler, IntPtr context);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetServiceStatus(IntPtr handle, ref ServiceStatus status);
}
