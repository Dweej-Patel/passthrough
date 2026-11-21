using Passthrough.Core.Shell.Sessions;

namespace Passthrough.Core.Shell.Serving;

/// <summary>
/// What a phone's connection needs from one Windows account's shells (stage 3 plan, "the seams"; stage 4 plan, section
/// 4): in the tray app itself (<see cref="LocalSessionHost"/>), or across the pipe from the service
/// (<c>PipeSessionHost</c>). Asynchronous from the start, since across the pipe every answer is a round trip. The
/// attachments are the phones' connections; output and the other notices reach them through
/// <see cref="IShellAttachment"/>, as from the session manager.
/// </summary>
public interface ISessionHost
{
    /// <summary>The sessions, as last known (across the pipe: the tray app's last list; empty while it is gone).</summary>
    IReadOnlyList<ShellSessionInfo> Sessions { get; }

    /// <summary>Fires when <see cref="Sessions"/> or <see cref="IsAvailable"/> changes.</summary>
    event Action? Changed;

    /// <summary>The account's shells can be reached now; false while its tray app isn't (phones are told <c>signed_out</c>).</summary>
    bool IsAvailable { get; }

    /// <summary>Starts a shell for <paramref name="phoneId"/>; throws <see cref="ShellException"/> with the reason a phone is told.</summary>
    Task<string> OpenAsync(string label, int cols, int rows, string phoneId, string? shell);

    /// <summary>
    /// Attaches <paramref name="client"/> to <paramref name="session"/>: replay, then live output. The
    /// <paramref name="generation"/> is the caller's (it knows it before any notice for it can arrive); a takeover
    /// notice carries it back. Throws <see cref="ShellException"/>.
    /// </summary>
    Task AttachAsync(string session, IShellAttachment client, int cols, int rows, ulong generation);

    /// <summary>Stops sending to <paramref name="client"/> without telling it.</summary>
    void Detach(IShellAttachment client);

    /// <summary>The client is gone for good (its connection closed): detached, and forgotten.</summary>
    void Gone(IShellAttachment client);

    /// <summary>The client has its terminal on screen, or not (<c>viewing</c>): a result that arrives while it does is seen.</summary>
    void SetViewing(IShellAttachment client, bool on);

    void Input(string session, byte[] input, IShellAttachment client);

    void Resize(string session, int cols, int rows, IShellAttachment client);

    void Close(string session);

    /// <summary>Ends every session <paramref name="phoneId"/> opened (it was revoked).</summary>
    void CloseSessions(string phoneId);

    /// <summary>Finished and running sessions, newest first. Throws <see cref="ShellException"/> (signed out).</summary>
    Task<IReadOnlyList<ShellHistoryEntry>> HistoryAsync();

    /// <summary>A transcript's end as the lines a phone is sent. Throws <see cref="ShellException"/> (<c>no_such_session</c>, signed out).</summary>
    Task<IReadOnlyList<ShellEnvelope>> TranscriptAsync(string session);
}

/// <summary>The shells of the account this process runs as: the session manager and its transcripts, in process.</summary>
public sealed class LocalSessionHost : ISessionHost
{
    public LocalSessionHost(ShellSessionManager manager, TranscriptStore transcripts)
    {
        Manager = manager;
        Transcripts = transcripts;
        manager.Changed += () => Changed?.Invoke();
    }

    public ShellSessionManager Manager { get; }
    public TranscriptStore Transcripts { get; }

    public IReadOnlyList<ShellSessionInfo> Sessions => Manager.Sessions;
    public event Action? Changed;
    public bool IsAvailable => true;

    public Task<string> OpenAsync(string label, int cols, int rows, string phoneId, string? shell) =>
        Task.Run(() => Manager.Open(label, cols, rows, phoneId, shell));

    public Task AttachAsync(string session, IShellAttachment client, int cols, int rows, ulong generation)
    {
        Manager.Attach(session, client, cols, rows, generation);
        return Task.CompletedTask;
    }

    public void Detach(IShellAttachment client) => Manager.Detach(client);
    public void Gone(IShellAttachment client) => Manager.Detach(client);
    public void SetViewing(IShellAttachment client, bool on)
    {
        if (on) Manager.LookedAt(client); // the client's own IsLooking says the rest
    }
    public void Input(string session, byte[] input, IShellAttachment client) => Manager.Input(session, input, client);
    public void Resize(string session, int cols, int rows, IShellAttachment client) => Manager.Resize(session, cols, rows, client);
    public void Close(string session) => Manager.Close(session);
    public void CloseSessions(string phoneId) => Manager.CloseSessions(phoneId);

    public Task<IReadOnlyList<ShellHistoryEntry>> HistoryAsync() => Task.Run<IReadOnlyList<ShellHistoryEntry>>(() => Transcripts.Entries());

    public Task<IReadOnlyList<ShellEnvelope>> TranscriptAsync(string session) => Task.Run<IReadOnlyList<ShellEnvelope>>(() =>
    {
        try { return ShellReplay.TranscriptLines(session, Transcripts.Replay(session)); }
        catch (Exception e) when (e is ArgumentException or IOException or UnauthorizedAccessException) { throw new ShellException(ShellError.NoSuchSession); }
    });
}
