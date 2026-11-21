// Throwaway spike: do the escape sequences Passthrough depends on pass through ConPTY intact
// and in order, with Windows' inbox pseudoconsole and with Microsoft's bundled one?
// See README.md for the question, how to run it, and the answers.
//
//   ConPtyProbe emit                       the child: writes the test sequences, reads what comes back
//   ConPtyProbe host inbox|bundled [options] [-- command args...]
//       --name N          label for the run (default: the mode)
//       --send MS:TEXT    write TEXT to the pseudoconsole's input MS ms after start (\e \r \n \\ escapes)
//       --resize-at TEXT  resize to 100x30 the first time TEXT appears in the output (default [[E]])
//       --kill-after MS   close the job MS ms after start and check every process in it is gone
//       --timeout MS      give up waiting for the child after MS ms (default 60000)
//       --dir PATH        working directory for the child

using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ConPtyProbe;

internal static unsafe class Program
{
    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "emit") return Emit.Run();
        if (args.Length > 1 && args[0] == "host") return Host.Run(args[1], args[2..]);
        if (args.Length > 1 && args[0] == "report") { Report.Print(File.ReadAllBytes(args[1])); return 0; }
        if (args.Length > 1 && args[0] == "show") { Console.WriteLine(Report.Show(System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(args[1])))); return 0; }
        Console.Error.WriteLine("usage: ConPtyProbe emit | host inbox|bundled [options] [-- command args...]");
        return 2;
    }
}

/// <summary>The test sequences, shared by the child (which writes them) and the host (which looks for them).</summary>
internal static class Seq
{
    public const string Esc = "\u001b";
    public const string St = Esc + "\\";
    public static readonly string Osc52 = Esc + "]52;c;aGVsbG8=\u0007";                       // "hello"
    public static readonly string StatusReport = Esc + "]7501;state=working:msg=dGVzdGluZw==" + St; // "testing"
    public static readonly string StatusQuery = Esc + "]7501;?" + St;
    public static readonly string DeviceAttributes = Esc + "[c";
    public static readonly string Dcs = Esc + "P1$r0m" + St;
    public static readonly string MiddleReport = Esc + "]7501;state=blocked:msg=bWlkZGxl" + St;     // "middle"
    /// <summary>What the Mac writes into a session that asked (protocol/README.md, Program status).</summary>
    public static readonly string StatusAnswer = Esc + "]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth" + St;
    public static readonly string DeviceAttributesAnswer = Esc + "[?62;22c";
    public static string Marker(char c) => $"[[{c}]]";
}

internal static class Emit
{
    public static int Run()
    {
        IntPtr hOut = Native.GetStdHandle(-11), hIn = Native.GetStdHandle(-10);
        Native.SetConsoleOutputCP(65001);
        Native.SetConsoleCP(65001);
        if (Native.GetConsoleMode(hOut, out uint outMode))
            Native.SetConsoleMode(hOut, outMode | 0x0001 | 0x0004); // processed output, virtual terminal processing
        if (Native.GetConsoleMode(hIn, out _))
            Native.SetConsoleMode(hIn, 0x0200); // virtual terminal input only: no line input, no echo, nothing processed

        var received = new List<byte>();
        var reader = new Thread(() =>
        {
            var buffer = new byte[4096];
            while (Native.ReadFile(hIn, buffer, buffer.Length, out int n, IntPtr.Zero) && n > 0)
                lock (received) received.AddRange(buffer.AsSpan(0, n).ToArray());
        }) { IsBackground = true };

        void Write(string s)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(s);
            Native.WriteFile(hOut, bytes, bytes.Length, out _, IntPtr.Zero);
        }

        Write(Seq.Marker('A') + Seq.Osc52 + Seq.Marker('B') + Seq.StatusReport + Seq.Marker('C') + Seq.StatusQuery + Seq.DeviceAttributes);
        reader.Start();
        Thread.Sleep(2000);
        byte[] got;
        lock (received) got = received.ToArray();
        string hex = Convert.ToHexString(got).ToLowerInvariant();
        var report = new StringBuilder("\r\n");
        for (int i = 0; i < hex.Length; i += 64) report.Append("[[R]] ").Append(hex.AsSpan(i, Math.Min(64, hex.Length - i))).Append("\r\n");
        report.Append("[[R/]]\r\n");
        Write(report.ToString());
        Write(Seq.Marker('D') + Seq.Dcs + Seq.Marker('E') + "\r\n");
        var lines = new StringBuilder();
        for (int i = 1; i <= 200; i++)
        {
            lines.Append($"line {i:000}\r\n");
            if (i == 100) lines.Append(Seq.MiddleReport);
            if (i % 20 == 0) { Write(lines.ToString()); lines.Clear(); Thread.Sleep(30); }
        }
        Write(Seq.Marker('F') + "\r\n");
        Thread.Sleep(300);
        return 0;
    }
}

internal static unsafe class Host
{
    private delegate int CreateFn(Native.COORD size, IntPtr input, IntPtr output, uint flags, out IntPtr pc);
    private delegate int ResizeFn(IntPtr pc, Native.COORD size);
    private delegate void CloseFn(IntPtr pc);

    public static int Run(string mode, string[] rest)
    {
        string name = mode;
        var sends = new List<(int At, string Text)>();
        string resizeAt = "[[E]]";
        int killAfter = -1, timeout = 60000;
        string? dir = null;
        bool noAnswer = false;
        string[] command = [Environment.ProcessPath!, "emit"];
        for (int i = 0; i < rest.Length; i++)
        {
            switch (rest[i])
            {
                case "--name": name = rest[++i]; break;
                case "--send":
                    string s = rest[++i]; int colon = s.IndexOf(':');
                    sends.Add((int.Parse(s[..colon]), Unescape(s[(colon + 1)..])));
                    break;
                case "--resize-at": resizeAt = rest[++i]; break;
                case "--kill-after": killAfter = int.Parse(rest[++i]); break;
                case "--timeout": timeout = int.Parse(rest[++i]); break;
                case "--dir": dir = rest[++i]; break;
                case "--no-answer": noAnswer = true; break;
                case "--": command = rest[(i + 1)..]; i = rest.Length; break;
                default: throw new ArgumentException(rest[i]);
            }
        }

        CreateFn create; ResizeFn resize; CloseFn close;
        if (mode == "inbox")
        {
            create = Native.CreatePseudoConsole; resize = Native.ResizePseudoConsole; close = Native.ClosePseudoConsole;
        }
        else if (mode == "bundled")
        {
            IntPtr lib = NativeLibrary.Load(Path.Combine(AppContext.BaseDirectory, "conpty.dll"));
            create = Marshal.GetDelegateForFunctionPointer<CreateFn>(NativeLibrary.GetExport(lib, "ConptyCreatePseudoConsole"));
            resize = Marshal.GetDelegateForFunctionPointer<ResizeFn>(NativeLibrary.GetExport(lib, "ConptyResizePseudoConsole"));
            close = Marshal.GetDelegateForFunctionPointer<CloseFn>(NativeLibrary.GetExport(lib, "ConptyClosePseudoConsole"));
        }
        else throw new ArgumentException(mode);

        string runs = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "runs");
        Directory.CreateDirectory(runs);
        string binPath = Path.GetFullPath(Path.Combine(runs, $"out-{name}.bin"));

        Check(Native.CreatePipe(out var inRead, out var inWrite, IntPtr.Zero, 0));
        Check(Native.CreatePipe(out var outRead, out var outWrite, IntPtr.Zero, 0));
        int hr = create(new Native.COORD(120, 30), inRead.DangerousGetHandle(), outWrite.DangerousGetHandle(), 0, out IntPtr pc);
        if (hr != 0) throw new Win32Exception(hr, "CreatePseudoConsole");
        inRead.Dispose(); outWrite.Dispose();

        IntPtr job = Native.CreateJobObject(IntPtr.Zero, null);
        var limits = new Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = 0x2000; // kill on job close
        Check(Native.SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf(limits)));

        var sw = Stopwatch.StartNew();
        var process = Start(command, dir, pc, job);
        Console.WriteLine($"== {name}: {string.Join(' ', command)}  (pid {process.ProcessId})");

        var output = new List<byte>();
        var inputStream = new FileStream(inWrite, FileAccess.Write, 1, false);
        var notes = new List<string>();
        void Send(string text, string why)
        {
            byte[] b = Encoding.UTF8.GetBytes(text);
            lock (inputStream) { inputStream.Write(b); inputStream.Flush(); }
            lock (notes) notes.Add($"{sw.ElapsedMilliseconds,6} ms  wrote {why}");
        }

        bool resized = false;
        var reader = new Thread(() =>
        {
            using var stream = new FileStream(outRead, FileAccess.Read, 1, false);
            var buffer = new byte[16384];
            int scanned = 0;
            var answered = new HashSet<(string, int)>();
            while (true)
            {
                int n;
                try { n = stream.Read(buffer); } catch (IOException) { break; }
                if (n <= 0) break;
                string text;
                lock (output) { output.AddRange(buffer.AsSpan(0, n).ToArray()); text = Encoding.Latin1.GetString(output.ToArray()); }
                int from = Math.Max(0, scanned - 64);
                foreach (var (ask, answer, label) in new[]
                {
                    (Seq.StatusQuery, Seq.StatusAnswer, "the 7501 support answer"),
                    (Seq.Esc + "]7501;?\u0007", Seq.StatusAnswer, "the 7501 support answer (BEL query)"),
                    (Seq.Esc + "[c", Seq.DeviceAttributesAnswer, "a device attributes answer"),
                    (Seq.Esc + "[0c", Seq.DeviceAttributesAnswer, "a device attributes answer (0c)"),
                    (Seq.Esc + "[6n", Seq.Esc + "[1;1R", "a cursor position answer"),
                })
                {
                    for (int at = text.IndexOf(ask, from, StringComparison.Ordinal); at >= 0; at = text.IndexOf(ask, at + 1, StringComparison.Ordinal))
                        if (answered.Add((ask, at)))
                        {
                            if (noAnswer) { lock (notes) notes.Add($"{sw.ElapsedMilliseconds,6} ms  left {label} unwritten (asked at byte {at})"); }
                            else Send(answer, $"{label} (asked at byte {at})");
                        }
                }
                if (!resized && text.IndexOf(resizeAt, from, StringComparison.Ordinal) >= 0)
                {
                    resized = true;
                    int r = resize(pc, new Native.COORD(100, 30));
                    lock (notes) notes.Add($"{sw.ElapsedMilliseconds,6} ms  resized to 100x30 (hr {r})");
                }
                scanned = text.Length;
            }
        }) { IsBackground = true };
        reader.Start();

        foreach (var (at, text) in sends)
        {
            var (a, t) = (at, text);
            _ = Task.Delay(a).ContinueWith(_ => Send(t, $"--send at {a} ms"));
        }

        var watcher = new Thread(() =>
        {
            string last = "";
            while (true)
            {
                var pids = JobPids(job);
                string now = string.Join(",", pids.Select(Describe));
                if (now != last) { lock (notes) notes.Add($"{sw.ElapsedMilliseconds,6} ms  job holds: {(now.Length == 0 ? "(nothing)" : now)}"); last = now; }
                if (pids.Count == 0 && sw.ElapsedMilliseconds > 1500) break;
                Thread.Sleep(250);
            }
        }) { IsBackground = true };
        watcher.Start();

        if (killAfter >= 0)
        {
            Thread.Sleep(killAfter);
            var before = JobPids(job);
            Native.CloseHandle(job);
            Thread.Sleep(1500);
            var alive = before.Where(IsAlive).ToList();
            notes.Add($"{sw.ElapsedMilliseconds,6} ms  closed the job holding {string.Join(",", before.Select(Describe))}; still alive after 1.5 s: {(alive.Count == 0 ? "none" : string.Join(",", alive))}");
        }
        else
        {
            uint wait = Native.WaitForSingleObject(process.Process, (uint)timeout);
            notes.Add($"{sw.ElapsedMilliseconds,6} ms  child {(wait == 0 ? "exited" : "TIMED OUT")}");
        }

        var closer = new Thread(() => close(pc)) { IsBackground = true };
        closer.Start();
        reader.Join(5000);
        closer.Join(3000);
        inputStream.Dispose();

        byte[] all;
        lock (output) all = output.ToArray();
        File.WriteAllBytes(binPath, all);
        lock (notes) foreach (string n in notes) Console.WriteLine("  " + n);
        Console.WriteLine($"  {all.Length} bytes recorded to {binPath}");
        if (command.Length == 2 && command[1] == "emit" || command.Any(c => c.Contains("emit.sh"))) Report.Print(all);
        return 0;
    }

    private static (IntPtr Process, int ProcessId) Start(string[] command, string? dir, IntPtr pc, IntPtr job)
    {
        IntPtr size = IntPtr.Zero;
        Native.InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
        IntPtr list = Marshal.AllocHGlobal(size);
        Check(Native.InitializeProcThreadAttributeList(list, 2, 0, ref size));
        Check(Native.UpdateProcThreadAttribute(list, 0, (IntPtr)0x00020016, pc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero));
        IntPtr jobs = Marshal.AllocHGlobal(IntPtr.Size);
        Marshal.WriteIntPtr(jobs, job);
        Check(Native.UpdateProcThreadAttribute(list, 0, (IntPtr)0x0002000D, jobs, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero));

        // The child's environment is the user's own, as a new logon would get it, never this process's.
        Check(Native.OpenProcessToken(Native.GetCurrentProcess(), 0x0008 | 0x0002, out IntPtr token));
        Check(Native.CreateEnvironmentBlock(out IntPtr block, token, false));
        var variables = new List<string>();
        for (IntPtr p = block; ;)
        {
            string entry = Marshal.PtrToStringUni(p)!;
            if (entry.Length == 0) break;
            variables.Add(entry);
            p += (entry.Length + 1) * 2;
        }
        Native.DestroyEnvironmentBlock(block);
        variables.RemoveAll(v => v.StartsWith("TERM_PROGRAM=", StringComparison.OrdinalIgnoreCase));
        variables.Add("TERM_PROGRAM=Passthrough");
        variables.Sort(StringComparer.OrdinalIgnoreCase);
        string environment = string.Join('\0', variables) + "\0\0";

        string application = Path.IsPathRooted(command[0]) ? command[0] : throw new ArgumentException("give the program as a full path");
        string commandLine = string.Join(' ', command.Select(Quote));
        var info = new Native.STARTUPINFOEX { lpAttributeList = list };
        info.StartupInfo.cb = Marshal.SizeOf<Native.STARTUPINFOEX>();
        info.StartupInfo.dwFlags = 0x00000100; // STARTF_USESTDHANDLES with none given: the child takes the pseudoconsole's, never ours
        fixed (char* env = environment)
        {
            Check(Native.CreateProcess(application, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                0x00080000 | 0x00000400, (IntPtr)env, dir, ref info, out var pi));
            Native.CloseHandle(pi.hThread);
            return (pi.hProcess, pi.dwProcessId);
        }
    }

    private static List<int> JobPids(IntPtr job)
    {
        const int max = 64;
        int size = 8 + max * IntPtr.Size;
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (!Native.QueryInformationJobObject(job, 3, buffer, size, IntPtr.Zero)) return [];
            int count = Marshal.ReadInt32(buffer, 4);
            return Enumerable.Range(0, count).Select(i => (int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size)).ToList();
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static string Describe(int pid)
    {
        try { return $"{Process.GetProcessById(pid).ProcessName}({pid})"; } catch { return $"?({pid})"; }
    }

    private static bool IsAlive(int pid)
    {
        try { return !Process.GetProcessById(pid).HasExited; } catch { return false; }
    }

    private static string Quote(string s) => s.Length > 0 && !s.Any(c => c == ' ' || c == '"' || c == '\t') ? s : "\"" + s.Replace("\"", "\\\"") + "\"";

    private static string Unescape(string s) =>
        s.Replace("\\\\", "\u0000").Replace("\\e", "\u001b").Replace("\\r", "\r").Replace("\\n", "\n").Replace("\u0000", "\\");

    private static void Check(bool ok)
    {
        if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}

/// <summary>Reads a recording of `emit` and says, for each sequence, whether it arrived intact and between its markers.</summary>
internal static class Report
{
    public static void Print(byte[] bytes)
    {
        string text = Encoding.Latin1.GetString(bytes);
        Console.WriteLine("  -- sequences (each must arrive intact, between the markers written around it)");
        Between(text, 'A', 'B', "OSC 52 clipboard", Seq.Osc52, Seq.Esc + "]52;");
        Between(text, 'B', 'C', "OSC 7501 report", Seq.StatusReport, Seq.Esc + "]7501;state=working");
        Between(text, 'C', null, "OSC 7501 query", Seq.StatusQuery, Seq.Esc + "]7501;?");
        Console.WriteLine($"     device attributes request reached the host: {(Find(text, Seq.DeviceAttributes) >= 0 ? "yes" : "no (the pseudoconsole answered it itself)")}");
        Between(text, 'D', 'E', "DCS string", Seq.Dcs, Seq.Esc + "P");

        int r = text.IndexOf("[[R]] ", StringComparison.Ordinal), rEnd = text.IndexOf("[[R/]]", StringComparison.Ordinal);
        if (r < 0 || rEnd < 0) Console.WriteLine("     what the child read back: (no report found)");
        else
        {
            var hex = new StringBuilder();
            foreach (string line in text[r..rEnd].Split("[[R]] ", StringSplitOptions.RemoveEmptyEntries))
                hex.Append(new string(line.TakeWhile(Uri.IsHexDigit).ToArray()));
            string back = Encoding.Latin1.GetString(Convert.FromHexString(hex.Length % 2 == 0 ? hex.ToString() : hex.ToString()[..^1]));
            Console.WriteLine($"     the child read back: {Show(back)}");
            Console.WriteLine($"       7501 answer intact: {(back.Contains(Seq.StatusAnswer) ? "yes" : "NO")}; device attributes answer: {(back.Contains(Seq.DeviceAttributesAnswer) ? "ours" : back.Contains(Seq.Esc + "[?") ? "another (the pseudoconsole's)" : "none")}");
            int sa = back.IndexOf(Seq.StatusAnswer, StringComparison.Ordinal), da = back.IndexOf(Seq.Esc + "[?", StringComparison.Ordinal);
            if (sa >= 0 && da >= 0) Console.WriteLine($"       7501 answer before the device attributes answer: {(sa < da ? "yes" : "NO")}");
        }

        int e = Find(text, Seq.Marker('E')), f = Find(text, Seq.Marker('F'));
        var missing = new List<int>();
        int last = -1; bool ordered = true;
        for (int i = 1; i <= 200; i++)
        {
            int at = text.IndexOf($"line {i:000}", Math.Max(0, e), StringComparison.Ordinal);
            if (at < 0) missing.Add(i);
            else { if (at < last) ordered = false; last = at; }
        }
        Console.WriteLine($"     200 lines across the resize: {(missing.Count == 0 ? "all present" : $"MISSING {string.Join(",", missing)}")}, {(ordered ? "in order" : "OUT OF ORDER")}");
        int l100 = text.IndexOf("line 100", Math.Max(0, e), StringComparison.Ordinal), l101 = text.IndexOf("line 101", Math.Max(0, e), StringComparison.Ordinal);
        int mid = Find(text, Seq.MiddleReport);
        Console.WriteLine($"     OSC 7501 between line 100 and 101: {(mid < 0 ? "MISSING" : mid > l100 && mid < l101 ? "intact, in place" : $"intact, MOVED (at {mid}, lines at {l100}/{l101})")}");
        Console.WriteLine($"     end marker: {(f >= 0 ? "present" : "MISSING")}");
    }

    private static void Between(string text, char before, char? after, string label, string exact, string prefix)
    {
        int b = Find(text, Seq.Marker(before));
        int a = after is char c ? Find(text, Seq.Marker(c)) : -1;
        int at = Find(text, exact);
        if (at >= 0)
        {
            bool placed = b >= 0 && at > b && (a < 0 || at < a);
            Console.WriteLine($"     {label}: intact, {(placed ? "in place" : $"MOVED (markers at {b}/{a}, sequence at {at})")}");
            return;
        }
        int p = Find(text, prefix);
        Console.WriteLine($"     {label}: {(p < 0 ? "MISSING" : "ALTERED: " + Show(text.Substring(p, Math.Min(80, text.Length - p))))}");
    }

    private static int Find(string text, string what) => text.IndexOf(what, StringComparison.Ordinal);

    public static string Show(string s) => new(s.SelectMany(ch => ch == '\u001b' ? "\\e" : ch == '\u0007' ? "\\a" : ch < ' ' ? $"\\x{(int)ch:x2}" : ch.ToString()).ToArray());
}

internal static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD(short x, short y) { public short X = x; public short Y = y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int cb; public string? lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS { public ulong a, b, c, d, e, f; }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll")] public static extern int CreatePseudoConsole(COORD size, IntPtr input, IntPtr output, uint flags, out IntPtr pc);
    [DllImport("kernel32.dll")] public static extern int ResizePseudoConsole(IntPtr pc, COORD size);
    [DllImport("kernel32.dll")] public static extern void ClosePseudoConsole(IntPtr pc);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attributes, int size);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcess(string application, StringBuilder commandLine, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr environment, string? directory, ref STARTUPINFOEX info, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int size, IntPtr returned);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint ms);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("userenv.dll", SetLastError = true)] public static extern bool CreateEnvironmentBlock(out IntPtr block, IntPtr token, bool inherit);
    [DllImport("userenv.dll")] public static extern bool DestroyEnvironmentBlock(IntPtr block);
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleOutputCP(uint cp);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleCP(uint cp);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool ReadFile(IntPtr handle, byte[] buffer, int count, out int read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool WriteFile(IntPtr handle, byte[] buffer, int count, out int written, IntPtr overlapped);
}
