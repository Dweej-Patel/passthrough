namespace Passthrough.Core.Shell.Access;

/// <summary>
/// What the cable side of the session needs from whoever holds phones' shell access: what a grant carries now, a
/// place to keep a key a phone confirmed, and a way to take a forgotten phone's access away. In stage 3 the tray app
/// holds it itself; from stage 4 the service does, behind a pipe (stage 3 plan, "the seams"). All calls run on the
/// session's loop and must not block it for long.
/// </summary>
public interface IAccessAdmin
{
    /// <summary>
    /// What a grant would carry now, or null when no grant should go out (Remote access off, or nothing to hand out
    /// yet). <see cref="GrantContents.Fingerprint"/> tells one grant's contents from another's.
    /// </summary>
    Task<GrantContents?> GrantContentsAsync();

    /// <summary>
    /// Keeps the key a phone confirmed it stored for a grant (<c>shellGranted</c>): <paramref name="phoneId"/> is the
    /// phone's own id, <paramref name="pairingSlot"/> the cable pairing it came through, <paramref name="label"/> what to
    /// call it. False when it could not be kept (the store failed, or the id belongs to another pairing).
    /// </summary>
    Task<bool> AddKeyAsync(string phoneId, string label, string pairingSlot, ReadOnlyMemory<byte> key);

    /// <summary>Takes away the shell access granted through a cable pairing (the pairing was forgotten): its keys first, then its connections and the sessions it opened.</summary>
    Task RevokeSlotAsync(string pairingSlot);

    /// <summary>Fires, on any thread, when what a grant carries may have changed (Remote access turned on or off, the endpoint came up, the relay changed).</summary>
    event Action? Changed;
}

/// <summary>Remote access isn't available: no grant goes out, nothing is kept, nothing to revoke.</summary>
public sealed class NoRemoteAccess : IAccessAdmin
{
    public static readonly NoRemoteAccess Instance = new();

    public Task<GrantContents?> GrantContentsAsync() => Task.FromResult<GrantContents?>(null);

    public Task<bool> AddKeyAsync(string phoneId, string label, string pairingSlot, ReadOnlyMemory<byte> key) => Task.FromResult(false);

    public Task RevokeSlotAsync(string pairingSlot) => Task.CompletedTask;

    public event Action? Changed { add { } remove { } }
}
