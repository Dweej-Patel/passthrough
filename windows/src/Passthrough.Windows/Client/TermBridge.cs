using System.Diagnostics;
using System.Security.Principal;
using Passthrough.Core.Client;
using Passthrough.Core.Pipe;
using Passthrough.Core.Trust;
using Passthrough.Windows.Iroh;
using Passthrough.Windows.Pipes;

namespace Passthrough.Windows.Client;

/// <summary>
/// A new shell on another computer, in a terminal (stage 8 a5): a one-instance pipe only this account can open, named
/// by 32 random hex digits (the one-time token: the name is passed only to the terminal this starts), then
/// <c>passthrough-term.exe</c> in a new Windows Terminal tab (a console window without it), titled "<i>MacBook</i> ·
/// shell". This end holds the connection and carries keys and output between the two.
/// </summary>
public static class TermBridge
{
    /// <summary>Opens a terminal on <paramref name="computer"/>; <paramref name="shell"/> is a chooser id the host listed (null: its default).</summary>
    public static Task OpenAsync(ReachableComputer computer, IComputerIdentity identity, string? shell, Action<string>? log = null)
    {
        var hex = Convert.ToHexStringLower(System.Security.Cryptography.RandomNumberGenerator.GetBytes(16));
        using var me = WindowsIdentity.GetCurrent();
        var pipe = PipeNative.CreateServer("Passthrough.Term." + hex, $"D:P(A;;GA;;;{me.User})", first: true, maxInstances: 1);
        Launch(hex, $"{computer.Credential.MacName} · {shell ?? "shell"}");
        return Task.Run(async () =>
        {
            await using (pipe)
            {
                using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                try { await pipe.WaitForConnectionAsync(wait.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { log?.Invoke("term: the terminal didn't connect"); return; }
                // Only the terminal this started may drive the shell, not another program of this account that found the name.
                if (!IsOurTerminal(PipeNative.ClientProcessId(pipe.SafePipeHandle))) { log?.Invoke("term: something other than passthrough-term connected"); return; }
                await BridgeAsync(pipe, computer, identity, shell, log).ConfigureAwait(false);
            }
        });
    }

    private static async Task BridgeAsync(Stream pipe, ReachableComputer computer, IComputerIdentity identity, string? shell, Action<string>? log)
    {
        var reader = new PipeFrameReader(pipe);
        if (await reader.ReadAsync().ConfigureAwait(false) is not { Kind: TermWire.Hello } hello || TermWire.ReadSize(hello) is not var (cols, rows)) return;
        var writeLock = new SemaphoreSlim(1, 1);
        async Task Write(PipeFrame frame)
        {
            await writeLock.WaitAsync().ConfigureAwait(false);
            try { await pipe.WriteAsync(frame.Encode()).ConfigureAwait(false); }
            catch (IOException) { }
            finally { writeLock.Release(); }
        }
        var c = computer.Credential;
        var credential = new ShellCredential(c.MacID, c.MacName, c.CertSHA256, Convert.FromBase64String(c.ShellKey), c.PhoneID, c.Port, c.Addresses,
            c.IrohID, c.IrohRelay, c.RelayToken, computer.HostKind);
        var done = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var client = new ShellClient(credential, new PinnedTlsDialer(), new IrohShellDialer(), e =>
        {
            switch (e)
            {
                case ShellClientEvent.Ready: break;
                case ShellClientEvent.Output o: _ = Write(new PipeFrame(TermWire.Output, o.Data.ToArray())); break;
                case ShellClientEvent.Ended end: done.TrySetResult(end.ExitStatus); break;
                case ShellClientEvent.OpenFailed f:
                    _ = Write(new PipeFrame(TermWire.Output, System.Text.Encoding.UTF8.GetBytes($"\r\n{f.Message ?? Passthrough.Core.Shell.ShellErrorWire.ToWire(f.Reason)}\r\n")));
                    done.TrySetResult(1);
                    break;
                case ShellClientEvent.Detached: done.TrySetResult(0); break;
                case ShellClientEvent.Disconnected d:
                    _ = Write(new PipeFrame(TermWire.Output, System.Text.Encoding.UTF8.GetBytes($"\r\n[Passthrough: the connection to {c.MacName} ended.]\r\n")));
                    log?.Invoke($"term: disconnected ({d.Error?.GetType().Name ?? "clean"})");
                    done.TrySetResult(2);
                    break;
            }
        }, identity: identity);
        client.Connect();
        // Queued now, sent first once the connection is up; keys before the session exists are dropped by the client.
        client.Open(cols, rows, shell);
        var keys = Task.Run(async () =>
        {
            try
            {
                while (await reader.ReadAsync().ConfigureAwait(false) is { } frame)
                {
                    if (frame.Kind == TermWire.Input) client.Input(frame.Payload);
                    else if (frame.Kind == TermWire.Resize && TermWire.ReadSize(frame) is var (c2, r2)) client.Resize(c2, r2);
                }
            }
            catch (IOException) { }
            done.TrySetResult(0); // the terminal closed: the session keeps running there
        });
        var status = await done.Task.ConfigureAwait(false);
        await Write(TermWire.EndedWith(status)).ConfigureAwait(false);
    }

    private static bool IsOurTerminal(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return string.Equals(process.MainModule?.FileName, Path.Combine(AppContext.BaseDirectory, "passthrough-term.exe"), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return false; }
    }

    /// <summary>A new tab in the current Windows Terminal window, or a console window when there is none.</summary>
    private static void Launch(string hex, string title)
    {
        var term = Path.Combine(AppContext.BaseDirectory, "passthrough-term.exe");
        var wt = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "wt.exe");
        // From the tray app (no console of its own) the terminal gets a console window of its own.
        var start = new ProcessStartInfo(File.Exists(wt) ? wt : term) { UseShellExecute = false };
        var arguments = File.Exists(wt) ? new[] { "-w", "0", "nt", "--title", title, term, "--pipe", hex } : ["--pipe", hex];
        foreach (var a in arguments) start.ArgumentList.Add(a);
        using var _ = Process.Start(start);
    }
}
