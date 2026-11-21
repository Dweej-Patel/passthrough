namespace Passthrough.Core.Transport;

public interface IProcessRunner
{
    /// <summary>Runs <paramref name="exe"/> with <paramref name="args"/>, waits for it, and returns its exit code.</summary>
    Task<int> RunAsync(string exe, string args, CancellationToken ct);
}
