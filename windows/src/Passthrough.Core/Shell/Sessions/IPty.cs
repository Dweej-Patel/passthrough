namespace Passthrough.Core.Shell.Sessions;

/// <summary>What starts a session's shell: a fixed program and arguments from the host's own catalog, never from the wire.</summary>
/// <param name="Id">The catalog's id for it (<see cref="HostShell.Id"/>), listed with the session.</param>
public sealed record ShellCommand(string Id, string Executable, IReadOnlyList<string> Arguments);

/// <summary>How to start a pseudo-terminal.</summary>
public sealed record PtyStart(
    string Executable,
    IReadOnlyList<string> Arguments,
    string Directory,
    IReadOnlyDictionary<string, string> Environment,
    int Cols,
    int Rows);

/// <summary>
/// A shell in a pseudo-terminal (ConPTY on Windows; a fake in tests). The session manager sets the callbacks, then
/// calls <see cref="Start"/>. Callbacks may come on any thread, one at a time per pseudo-terminal, output before exit.
/// </summary>
public interface IPty : IDisposable
{
    /// <summary>Output, as the program wrote it. The buffer is the callee's to keep.</summary>
    Action<byte[]>? OnOutput { get; set; }

    /// <summary>The shell exited (or was ended), with its exit code; after the last output.</summary>
    Action<int>? OnExit { get; set; }

    void Start();

    /// <summary>Typing, in order. Never blocks: a pseudo-terminal that isn't reading queues it.</summary>
    void Write(ReadOnlySpan<byte> data);

    void Resize(int cols, int rows);

    /// <summary>Ends the shell and everything it started; <see cref="OnExit"/> follows.</summary>
    void Terminate();

    /// <summary>
    /// What runs in front now, as a token that changes when another program comes to the front (on the Mac, the
    /// foreground process group); null when it can't be told.
    /// </summary>
    long? ForegroundJob { get; }

    /// <summary>Whether anything of <paramref name="job"/> still runs.</summary>
    bool JobExists(long job);

    /// <summary>The shell itself is in front, not a program it started.</summary>
    bool ShellIsInFront(long? job);
}

/// <summary>Whoever is looking at a session right now. Called in order on a callout thread, never under the manager's lock.</summary>
public interface IShellAttachment
{
    void ShellOutput(byte[] data, string session);
    void ShellEnded(string session, int exitStatus);

    /// <summary>
    /// Another client attached to the session and took it over. <paramref name="generation"/> is that of the attach that
    /// returned it: a notice queued before the client attached again belongs to the older attach.
    /// </summary>
    void ShellDetached(string session, ulong generation);

    /// <summary>The scrollback replay for an attach comes next: output handed over before this was live, and is in the replay too.</summary>
    void ShellReplaying(string session) { }

    /// <summary>The scrollback replay for an attach has been handed over; what follows is live.</summary>
    void ShellReplayed(string session) { }

    /// <summary>Someone is looking at what this client shows: a result that arrives then is seen.</summary>
    bool IsLooking => true;
}

/// <summary>A session can't be opened or used; carries the reason a phone is told.</summary>
public sealed class ShellException(ShellError error, string? message = null) : Exception(message ?? error.ToString())
{
    public ShellError Error { get; } = error;
}
