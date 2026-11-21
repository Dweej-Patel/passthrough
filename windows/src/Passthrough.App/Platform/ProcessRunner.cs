using System.Diagnostics;
using Passthrough.Core.Transport;

namespace Passthrough.App.Platform;

/// <summary>Runs a program with no window and waits for it (used for <c>adb start-server</c>).</summary>
public sealed class ProcessRunner : IProcessRunner
{
    public async Task<int> RunAsync(string exe, string args, CancellationToken ct)
    {
        var info = new ProcessStartInfo(exe, args)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        using var process = Process.Start(info) ?? throw new InvalidOperationException($"Could not start {exe}.");
        try
        {
            await process.WaitForExitAsync(ct);
        }
        catch (OperationCanceledException)
        {
            // Stopped, or past Core's start-up limit (AdbClient.ServerStartTimeout): kill it.
            try { process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { } // it exited just now
            throw;
        }
        return process.ExitCode;
    }
}
