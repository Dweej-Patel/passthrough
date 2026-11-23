using System.IO.Pipes;
using System.Runtime.InteropServices;
using Passthrough.Core.Client;
using Passthrough.Core.Pipe;

namespace Passthrough.Term;

/// <summary>
/// <c>passthrough-term.exe --pipe &lt;hex&gt;</c>: the console end of another computer's shell. Raw VT input (Ctrl+C
/// and Ctrl+Break go to the shell, not to this process), UTF-8 both ways, resizes as the window changes, and the
/// console's modes put back on exit, however it ends.
/// </summary>
internal static class Program
{
    private const uint EnableProcessedInput = 0x1, EnableLineInput = 0x2, EnableEchoInput = 0x4, EnableVirtualTerminalInput = 0x200;
    private const uint EnableProcessedOutput = 0x1, EnableVirtualTerminalProcessing = 0x4, DisableNewlineAutoReturn = 0x8;
    private static uint _inputMode, _outputMode;
    private static IntPtr _in, _out;

    private static async Task<int> Main(string[] args)
    {
        var i = Array.IndexOf(args, "--pipe");
        if (i < 0 || i + 1 >= args.Length || args[i + 1].Length != 32 || !args[i + 1].All(Uri.IsHexDigit))
        {
            Console.Error.WriteLine("Open a computer's shell from Passthrough's tray icon.");
            return 64;
        }
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        Console.InputEncoding = System.Text.Encoding.UTF8;
        using var pipe = new NamedPipeClientStream(".", "Passthrough.Term." + args[i + 1], PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try { await pipe.ConnectAsync(5000); }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine("Passthrough isn't answering. Open the shell again from its tray icon.");
            return 2;
        }
        Raw();
        AppDomain.CurrentDomain.ProcessExit += (_, _) => Restore();
        try
        {
            var (cols, rows) = (Console.WindowWidth, Console.WindowHeight);
            await pipe.WriteAsync(TermWire.Size(TermWire.Hello, cols, rows).Encode());
            using var stop = new CancellationTokenSource();
            var keys = Task.Run(() => PumpKeys(pipe, stop.Token));
            var sizes = Task.Run(() => WatchSize(pipe, cols, rows, stop.Token));
            var stdout = Console.OpenStandardOutput();
            var reader = new PipeFrameReader(pipe);
            var status = 0;
            while (await reader.ReadAsync() is { } frame)
            {
                if (frame.Kind == TermWire.Output) { await stdout.WriteAsync(frame.Payload); await stdout.FlushAsync(); }
                else if (frame.Kind == TermWire.Status) Console.Title = System.Text.Encoding.UTF8.GetString(frame.Payload.Span);
                else if (frame.Kind == TermWire.Ended) { status = TermWire.ReadStatus(frame); break; }
            }
            stop.Cancel();
            return status;
        }
        catch (IOException) { return 3; }
        finally { Restore(); }
    }

    private static async Task PumpKeys(Stream pipe, CancellationToken stop)
    {
        var stdin = Console.OpenStandardInput();
        var buffer = new byte[4096];
        while (!stop.IsCancellationRequested)
        {
            var n = await stdin.ReadAsync(buffer, stop);
            if (n == 0) break;
            await pipe.WriteAsync(new PipeFrame(TermWire.Input, buffer.AsMemory(0, n).ToArray()).Encode(), stop);
        }
    }

    private static async Task WatchSize(Stream pipe, int cols, int rows, CancellationToken stop)
    {
        while (!stop.IsCancellationRequested)
        {
            await Task.Delay(250, stop);
            var (c, r) = (Console.WindowWidth, Console.WindowHeight);
            if ((c, r) == (cols, rows)) continue;
            (cols, rows) = (c, r);
            await pipe.WriteAsync(TermWire.Size(TermWire.Resize, c, r).Encode(), stop);
        }
    }

    /// <summary>Keys as VT sequences, nothing cooked, nothing echoed; output interpreted as VT.</summary>
    private static void Raw()
    {
        _in = GetStdHandle(-10);
        _out = GetStdHandle(-11);
        GetConsoleMode(_in, out _inputMode);
        GetConsoleMode(_out, out _outputMode);
        SetConsoleMode(_in, (_inputMode & ~(EnableProcessedInput | EnableLineInput | EnableEchoInput)) | EnableVirtualTerminalInput);
        SetConsoleMode(_out, _outputMode | EnableProcessedOutput | EnableVirtualTerminalProcessing | DisableNewlineAutoReturn);
    }

    private static int _restored;

    private static void Restore()
    {
        if (Interlocked.Exchange(ref _restored, 1) == 1) return;
        SetConsoleMode(_in, _inputMode);
        SetConsoleMode(_out, _outputMode);
        // Whatever the remote shell left on: alternate screen off, cursor shown, mouse reporting and bracketed paste off.
        Console.Out.Write("\u001b[?1049l\u001b[?25h\u001b[?1000l\u001b[?1002l\u001b[?1006l\u001b[?2004l\u001b[0m");
        Console.Out.Flush();
    }

    [DllImport("kernel32.dll")] private static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll")] private static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll")] private static extern bool SetConsoleMode(IntPtr handle, uint mode);
}
