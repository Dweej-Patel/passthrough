using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Passthrough.Core.Setup;
using Passthrough.Windows.Pipes;

namespace Passthrough.Windows.Setup;

/// <summary>What the tray app hands the elevated process over the setup pipe (never on its command line).</summary>
public sealed record SetupInput
{
    /// <summary>For <c>--configure relay</c>: the relay's URL (null: n0's), and its token.</summary>
    public string? RelayUrl { get; init; }
    public string? RelayToken { get; init; }

    private static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public string Encode() => JsonSerializer.Serialize(this, Options);

    public static SetupInput Decode(string? line)
    {
        if (string.IsNullOrWhiteSpace(line) || line.Length > 16384) return new SetupInput();
        try { return JsonSerializer.Deserialize<SetupInput>(line, Options) ?? new SetupInput(); }
        catch (JsonException) { return new SetupInput(); }
    }
}

/// <summary>
/// The tray app's end of an elevated verb (stage 4 plan, section 3): a one-instance pipe only this account,
/// administrators and SYSTEM can open, then <c>Passthrough.Service.exe &lt;verb&gt; --report &lt;hex&gt;</c> run as
/// administrator behind one prompt. The elevated process learns who asked from this pipe's server process, never from
/// an argument, and reports a line per step and a result.
/// </summary>
public static class ElevatedSetup
{
    public const string PipePrefix = "Passthrough.Setup.";
    public static readonly TimeSpan Limit = TimeSpan.FromSeconds(120);

    public static async Task<SetupResult> RunAsync(string exe, IReadOnlyList<string> arguments, SetupInput input, Action<StepReport> progress, Action<string>? log = null,
        CancellationToken cancel = default)
    {
        var hex = Convert.ToHexStringLower(System.Security.Cryptography.RandomNumberGenerator.GetBytes(16));
        using var me = WindowsIdentity.GetCurrent();
        await using var pipe = PipeNative.CreateServer(PipePrefix + hex, $"D:P(A;;GA;;;{me.User})(A;;GA;;;BA)(A;;GA;;;SY)", first: true, maxInstances: 1);
        Process? process;
        try
        {
            process = Process.Start(new ProcessStartInfo(exe)
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
                Arguments = string.Join(' ', arguments.Concat(["--report", hex]).Select(Quote)),
                WorkingDirectory = Path.GetDirectoryName(exe),
            });
        }
        catch (Win32Exception e) when (e.NativeErrorCode == 1223) // ERROR_CANCELLED: the prompt was declined
        {
            return new SetupResult { Result = SetupResult.Declined, Refused = true };
        }
        if (process is null) return new SetupResult { Result = SetupResult.Failed, Refused = true, Error = "Windows didn't start the setup." };
        using (process)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            timeout.CancelAfter(Limit);
            SetupResult? result = null;
            try
            {
                var connected = pipe.WaitForConnectionAsync(timeout.Token);
                var exited = process.WaitForExitAsync(timeout.Token);
                if (await Task.WhenAny(connected, exited).ConfigureAwait(false) == connected)
                {
                    await connected.ConfigureAwait(false);
                    var bytes = Encoding.UTF8.GetBytes(input.Encode() + "\n");
                    await pipe.WriteAsync(bytes, timeout.Token).ConfigureAwait(false);
                    using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
                    while (await reader.ReadLineAsync(timeout.Token).ConfigureAwait(false) is { } line)
                    {
                        if (line.Length > 16384) break;
                        var (step, last) = SetupLines.Decode(line);
                        if (step is not null)
                        {
                            log?.Invoke($"setup: {step.Step} {step.State.ToString().ToLowerInvariant()}{(step.Detail is null ? "" : ": " + step.Detail)}");
                            progress(step);
                        }
                        if (last is not null) result = last;
                    }
                }
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return new SetupResult { Result = SetupResult.Failed, Error = "The setup didn't finish in time. See the log." };
            }
            catch (IOException) { }
            log?.Invoke($"setup: exited with {process.ExitCode}");
            return result ?? new SetupResult { Result = SetupResult.Failed, Error = "The setup stopped without saying why. See the log.", Undone = false };
        }
    }

    private static string Quote(string argument) => argument.Length > 0 && !argument.Any(c => c is ' ' or '"' or '\t') ? argument : "\"" + argument.Replace("\"", "\\\"") + "\"";
}

/// <summary>The elevated process's end of the setup pipe: who asked, what it handed over, and where the lines go.</summary>
public sealed class SetupReporter : IDisposable
{
    private readonly NamedPipeClientStream _pipe;
    private readonly StreamWriter _writer;

    private SetupReporter(NamedPipeClientStream pipe, SecurityIdentifier asking, SetupInput input)
    {
        _pipe = pipe;
        _writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
        AskingAccount = asking;
        Input = input;
    }

    /// <summary>The account whose tray app asked: the pipe's server process's token, not this process's (an administrator's password may have been typed for a standard user).</summary>
    public SecurityIdentifier AskingAccount { get; }

    public SetupInput Input { get; }

    /// <summary>Opens the pipe named by <paramref name="hex"/> without lending it this process's identity; null when it isn't a tray app in a user's session.</summary>
    public static SetupReporter? Connect(string hex)
    {
        if (hex.Length != 32 || !hex.All(Uri.IsHexDigit)) return null;
        NamedPipeClientStream pipe;
        try { pipe = PipeNative.OpenClient(ElevatedSetup.PipePrefix + hex, anonymous: true); }
        catch (Win32Exception) { return null; }
        var server = PipeNative.ProcessAccount(PipeNative.ServerProcessId(pipe.SafePipeHandle));
        if (server is not { Session: > 0 } account) { pipe.Dispose(); return null; }
        string? line;
        using (var reader = new StreamReader(pipe, Encoding.UTF8, detectEncodingFromByteOrderMarks: false, bufferSize: 1, leaveOpen: true))
            line = reader.ReadLine();
        return new SetupReporter(pipe, account.User, SetupInput.Decode(line));
    }

    public void Report(StepReport step) => Write(SetupLines.Encode(step));

    public void Report(SetupResult result) => Write(SetupLines.Encode(result));

    private void Write(string line)
    {
        try { _writer.WriteLine(line); }
        catch (IOException) { } // the tray app went: the steps go on, setup.log has them
    }

    public void Dispose()
    {
        try { _writer.Dispose(); } catch (IOException) { }
        _pipe.Dispose();
    }
}
