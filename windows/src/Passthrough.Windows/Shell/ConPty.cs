using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Passthrough.Core.Shell.Sessions;

namespace Passthrough.Windows.Shell;

/// <summary>
/// A shell in a pseudoconsole: Microsoft's bundled ConPTY (conpty.dll and x64\OpenConsole.exe beside the app, loaded by
/// full path; never the inbox one, which breaks OSC 7501), the shell in a kill-on-close job object so ending the session
/// ends everything it started. Output is read on a thread of its own, typing written on another, so neither side ever
/// waits on the other; the exit is reported after the last output.
/// </summary>
public sealed unsafe class ConPty : IPty
{
    /// <summary>What a session ended from this side reports, as a console program stopped with Ctrl+C does.</summary>
    public const int TerminatedExitCode = unchecked((int)0xC000013A);

    private static readonly Lazy<Api> Functions = new(Api.Load);

    private readonly PtyStart _start;
    private readonly SafeJobHandle _job;
    private readonly IntPtr _console;
    private readonly SafeFileHandle _inputWrite;
    private readonly SafeFileHandle _outputRead;
    private readonly BlockingCollection<byte[]> _typing = new(new ConcurrentQueue<byte[]>());
    private readonly ConPtyOutputFilter _filter = new();
    private readonly Lock _lock = new();
    private SafeProcessHandle? _process;
    private int _shellPid;
    private bool _started;
    private bool _consoleClosed;
    private int _terminated;
    /// <summary>
    /// What <see cref="ForegroundJob"/> found last, with the job's process counts then: until a process starts or ends
    /// in the job, what is in front can't have changed, so a burst of output asks the job once per chunk, cheaply.
    /// </summary>
    private ((uint Started, uint Running) Counts, long Job)? _foreground;

    public Action<byte[]>? OnOutput { get; set; }
    public Action<int>? OnExit { get; set; }

    /// <summary>
    /// SHA-256 of Microsoft.Windows.Console.ConPTY 1.25.261109001's x64 binaries, both signed by Microsoft (B-12; the
    /// test also checks the signature chain). Updating the package means updating these, in the same PR.
    /// </summary>
    internal const string ConptyDllSha256 = "e971856f89748dc3b458125e9afdd79b5e9574a7c937676116d3cbbd3b71f492";
    internal const string OpenConsoleSha256 = "b17e48b07ef153b420f0a6e178bacd31fb4c3390e21ae746586213fc0719a775";

    internal static string OpenConsolePath => Path.Combine(AppContext.BaseDirectory, "x64", "OpenConsole.exe");

    private static readonly Lazy<bool> Verified = new(() =>
        Matches(Api.LibraryPath, ConptyDllSha256) && Matches(OpenConsolePath, OpenConsoleSha256));

    /// <summary>Whether this PC can run sessions: the bundled pseudoconsole is beside the app, byte for byte the one pinned.</summary>
    public static bool IsAvailable => Verified.Value;

    private static bool Matches(string path, string sha256)
    {
        try
        {
            using var file = File.OpenRead(path);
            return Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(file)) == sha256;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    public ConPty(PtyStart start)
    {
        _start = start;
        if (!Path.IsPathFullyQualified(start.Executable)) throw new ArgumentException("a shell is started by its full path", nameof(start));
        if (!IsAvailable) throw new InvalidOperationException("the bundled pseudoconsole is missing or isn't the one pinned");
        var api = Functions.Value;
        Native.Check(Native.CreatePipe(out var inputRead, out _inputWrite, IntPtr.Zero, 0), "CreatePipe");
        Native.Check(Native.CreatePipe(out _outputRead, out var outputWrite, IntPtr.Zero, 0), "CreatePipe");
        IntPtr console;
        var hr = api.Create(Size(start.Cols, start.Rows), inputRead.DangerousGetHandle(), outputWrite.DangerousGetHandle(), 0, &console);
        // The pseudoconsole holds its own duplicates of its ends.
        inputRead.Dispose();
        outputWrite.Dispose();
        if (hr != 0)
        {
            _inputWrite.Dispose();
            _outputRead.Dispose();
            throw new System.ComponentModel.Win32Exception(hr, "ConptyCreatePseudoConsole");
        }
        _console = console;
        _job = Native.CreateJobObject(IntPtr.Zero, null);
        if (_job.IsInvalid) { Cleanup(); throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError(), "CreateJobObject"); }
        var limits = new Native.JobObjectExtendedLimitInformation();
        limits.BasicLimitInformation.LimitFlags = Native.JobObjectLimitKillOnJobClose;
        if (!Native.SetInformationJobObject(_job, Native.JobObjectExtendedLimitInformationClass, ref limits, Marshal.SizeOf(limits)))
        {
            var error = Marshal.GetLastPInvokeError();
            Cleanup();
            throw new System.ComponentModel.Win32Exception(error, "SetInformationJobObject");
        }
    }

    public int ProcessId => _shellPid;

    public void Start()
    {
        lock (_lock)
        {
            if (_started) throw new InvalidOperationException("started already");
            _started = true;
        }
        (_process, _shellPid) = StartProcess();
        new Thread(ReadOutput) { IsBackground = true, Name = "conpty output" }.Start();
        new Thread(WriteTyping) { IsBackground = true, Name = "conpty input" }.Start();
        new Thread(WaitForExit) { IsBackground = true, Name = "conpty exit" }.Start();
    }

    public void Write(ReadOnlySpan<byte> data)
    {
        if (data.IsEmpty) return;
        try { _typing.Add(data.ToArray()); }
        catch (InvalidOperationException) { } // ended: typing has nowhere to go
    }

    public void Resize(int cols, int rows)
    {
        lock (_lock)
        {
            if (_consoleClosed) return;
            Functions.Value.Resize(_console, Size(cols, rows));
        }
    }

    public void Terminate()
    {
        if (Interlocked.Exchange(ref _terminated, 1) == 1) return;
        lock (_lock)
        {
            if (_started && !_job.IsClosed) Native.TerminateJobObject(_job, unchecked((uint)TerminatedExitCode));
        }
    }

    public long? ForegroundJob
    {
        get
        {
            if (_shellPid == 0) return null;
            var counts = Counts();
            if (counts is null) return null;
            lock (_lock) if (_foreground is { } last && last.Counts == counts) return last.Job;
            var job = FindForeground();
            lock (_lock) _foreground = (counts.Value, job);
            return job;
        }
    }

    public bool JobExists(long job) => JobPids().Contains((int)job);

    public bool ShellIsInFront(long? job) => job is { } j && j == _shellPid;

    public void Dispose()
    {
        bool started;
        lock (_lock) started = _started;
        if (!started) { Cleanup(); return; }
        Terminate(); // the exit thread closes the rest
    }

    // MARK: Threads

    private void ReadOutput()
    {
        try { ReadAll(); }
        finally { _readerDone.Set(); }
    }

    private void ReadAll()
    {
        using var stream = new FileStream(_outputRead, FileAccess.Read, 1, isAsync: false);
        var buffer = new byte[65536];
        while (true)
        {
            int read;
            try { read = stream.Read(buffer); }
            catch (IOException) { break; }
            if (read <= 0) break;
            Deliver(_filter.Filter(buffer.AsSpan(0, read)));
        }
        Deliver(_filter.Flush());
    }

    private void Deliver(byte[] data)
    {
        if (data.Length == 0) return;
        try { OnOutput?.Invoke(data); }
        catch (Exception) { /* the session's failure is its own; keep reading so the shell never blocks */ }
    }

    private void WriteTyping()
    {
        using var stream = new FileStream(_inputWrite, FileAccess.Write, 1, isAsync: false);
        try
        {
            foreach (var data in _typing.GetConsumingEnumerable())
            {
                stream.Write(data);
                stream.Flush();
            }
        }
        catch (IOException) { } // the pseudoconsole is gone
    }

    private void WaitForExit()
    {
        Native.WaitForSingleObject(_process!, Native.Infinite);
        var code = Native.GetExitCodeProcess(_process!, out var exit) ? unchecked((int)exit) : TerminatedExitCode;
        // What the shell left running goes with it, as a hangup would end it on a Mac.
        lock (_lock) if (!_job.IsClosed) Native.TerminateJobObject(_job, unchecked((uint)TerminatedExitCode));
        _typing.CompleteAdding();
        lock (_lock)
        {
            // Closing the pseudoconsole flushes what it still holds and ends the output pipe.
            if (!_consoleClosed) { Functions.Value.Close(_console); _consoleClosed = true; }
        }
        _readerDone.Wait(TimeSpan.FromSeconds(5));
        Cleanup();
        try { OnExit?.Invoke(code); }
        catch (Exception) { }
    }

    private readonly ManualResetEventSlim _readerDone = new();

    // MARK: Starting

    private (SafeProcessHandle, int) StartProcess()
    {
        var size = IntPtr.Zero;
        Native.InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
        var list = Marshal.AllocHGlobal(size);
        var jobs = Marshal.AllocHGlobal(IntPtr.Size);
        try
        {
            Native.Check(Native.InitializeProcThreadAttributeList(list, 2, 0, ref size), "InitializeProcThreadAttributeList");
            try
            {
                Native.Check(Native.UpdateProcThreadAttribute(list, 0, Native.ProcThreadAttributePseudoConsole, _console, IntPtr.Size, IntPtr.Zero, IntPtr.Zero), "pseudoconsole attribute");
                // In the job from its first instruction, so nothing it starts can escape before it is assigned.
                Marshal.WriteIntPtr(jobs, _job.DangerousGetHandle());
                Native.Check(Native.UpdateProcThreadAttribute(list, 0, Native.ProcThreadAttributeJobList, jobs, IntPtr.Size, IntPtr.Zero, IntPtr.Zero), "job attribute");
                var info = new Native.StartupInfoEx { lpAttributeList = list };
                info.StartupInfo.cb = Marshal.SizeOf<Native.StartupInfoEx>();
                // Standard handles given as none: the shell takes the pseudoconsole's, never this process's.
                info.StartupInfo.dwFlags = Native.StartfUseStdHandles;
                var commandLine = CommandLine.Build(_start.Executable, _start.Arguments) + '\0';
                var environment = CommandLine.EnvironmentBlock(_start.Environment);
                fixed (char* line = commandLine)
                fixed (char* env = environment)
                {
                    Native.Check(Native.CreateProcess(_start.Executable, line, IntPtr.Zero, IntPtr.Zero, false,
                        Native.ExtendedStartupInfoPresent | Native.CreateUnicodeEnvironment, env,
                        Directory.Exists(_start.Directory) ? _start.Directory : null, ref info, out var pi), "CreateProcess");
                    Native.CloseHandle(pi.hThread);
                    return (new SafeProcessHandle(pi.hProcess, ownsHandle: true), pi.dwProcessId);
                }
            }
            finally { Native.DeleteProcThreadAttributeList(list); }
        }
        finally
        {
            Marshal.FreeHGlobal(jobs);
            Marshal.FreeHGlobal(list);
        }
    }

    // MARK: What is in front

    /// <summary>The oldest program the shell itself started that still runs, else the shell: what a person ran at the prompt.</summary>
    private long FindForeground()
    {
        long best = _shellPid, bestCreated = long.MaxValue;
        foreach (var pid in JobPids())
        {
            if (pid == _shellPid) continue;
            using var process = Native.OpenProcess(Native.ProcessQueryLimitedInformation, false, pid);
            if (process.IsInvalid) continue;
            if (Native.NtQueryInformationProcess(process, 0, out var basic, Marshal.SizeOf<Native.ProcessBasicInformation>(), out _) != 0) continue;
            if ((long)basic.InheritedFromUniqueProcessId != _shellPid) continue;
            if (!Native.GetProcessTimes(process, out var created, out _, out _, out _)) continue;
            if (created < bestCreated) (best, bestCreated) = (pid, created);
        }
        return best;
    }

    private (uint Started, uint Running)? Counts()
    {
        lock (_lock)
        {
            if (_job.IsClosed || !Native.QueryInformationJobObject(_job, Native.JobObjectBasicAccountingInformation, out Native.JobObjectBasicAccounting info, Marshal.SizeOf<Native.JobObjectBasicAccounting>(), IntPtr.Zero)) return null;
            return (info.TotalProcesses, info.ActiveProcesses);
        }
    }

    private List<int> JobPids()
    {
        const int max = 512;
        var size = 8 + max * IntPtr.Size;
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            lock (_lock) if (_job.IsClosed || !Native.QueryInformationJobObject(_job, Native.JobObjectBasicProcessIdList, buffer, size, IntPtr.Zero)) return [];
            var count = Marshal.ReadInt32(buffer, 4);
            var pids = new List<int>(count);
            for (var i = 0; i < count; i++) pids.Add((int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size));
            return pids;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private void Cleanup()
    {
        lock (_lock)
        {
            if (!_consoleClosed && _console != IntPtr.Zero) { Functions.Value.Close(_console); _consoleClosed = true; }
            _job?.Dispose();
            _process?.Dispose();
        }
        _typing.CompleteAdding();
        if (!_started)
        {
            _inputWrite?.Dispose();
            _outputRead?.Dispose();
        }
    }

    private static Native.Coord Size(int cols, int rows) =>
        new((short)Math.Clamp(cols, 1, short.MaxValue), (short)Math.Clamp(rows, 1, short.MaxValue));

    /// <summary>The bundled pseudoconsole's exports.</summary>
    private sealed class Api
    {
        public static string LibraryPath => Path.Combine(AppContext.BaseDirectory, "conpty.dll");

        public required delegate* unmanaged[Stdcall]<Native.Coord, IntPtr, IntPtr, uint, IntPtr*, int> CreateFn { get; init; }
        public required delegate* unmanaged[Stdcall]<IntPtr, Native.Coord, int> ResizeFn { get; init; }
        public required delegate* unmanaged[Stdcall]<IntPtr, void> CloseFn { get; init; }

        public int Create(Native.Coord size, IntPtr input, IntPtr output, uint flags, IntPtr* console) => CreateFn(size, input, output, flags, console);
        public void Resize(IntPtr console, Native.Coord size) => ResizeFn(console, size);
        public void Close(IntPtr console) => CloseFn(console);

        public static Api Load()
        {
            // By full path: never a conpty.dll found on the search path.
            var library = NativeLibrary.Load(LibraryPath);
            return new Api
            {
                CreateFn = (delegate* unmanaged[Stdcall]<Native.Coord, IntPtr, IntPtr, uint, IntPtr*, int>)NativeLibrary.GetExport(library, "ConptyCreatePseudoConsole"),
                ResizeFn = (delegate* unmanaged[Stdcall]<IntPtr, Native.Coord, int>)NativeLibrary.GetExport(library, "ConptyResizePseudoConsole"),
                CloseFn = (delegate* unmanaged[Stdcall]<IntPtr, void>)NativeLibrary.GetExport(library, "ConptyClosePseudoConsole"),
            };
        }
    }
}
