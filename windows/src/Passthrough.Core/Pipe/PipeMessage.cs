using Passthrough.Core.Shell;

namespace Passthrough.Core.Pipe;

/// <summary>
/// The JSON payload of every frame that isn't output or input: each kind uses the fields it needs (stage 4 plan,
/// section 4). <c>id</c> pairs a request with its <see cref="PipeKind.Reply"/>; <c>conn</c> names a phone's
/// connection, a number the service chose. No frame names a Windows account: the service knows the tray app's from its
/// token.
/// </summary>
public sealed record PipeMessage
{
    public uint? Id { get; init; }
    public uint? Conn { get; init; }
    public string? Phone { get; init; }
    public string? Label { get; init; }
    public string? Shell { get; init; }
    public int? Cols { get; init; }
    public int? Rows { get; init; }
    public string? Session { get; init; }
    public ulong? Generation { get; init; }
    public bool? On { get; init; }
    public int? ExitStatus { get; init; }
    /// <summary>A <see cref="ShellError"/> wire value: the request failed.</summary>
    public string? Error { get; init; }
    /// <summary>A sentence for the phone, with some errors.</summary>
    public string? Message { get; init; }
    public List<ShellSessionInfo>? Sessions { get; init; }
    public List<ShellHistoryEntry>? History { get; init; }
    /// <summary>A transcript's lines, each one encoded line as a phone is sent it.</summary>
    public List<string>? Lines { get; init; }
    /// <summary>The last chunk of a transcript.</summary>
    public bool? Last { get; init; }
    public PipeHostState? State { get; init; }
}

/// <summary>What the tray app says about its account's side of the PC (<see cref="PipeKind.HostState"/>): the service builds <c>host</c> and <c>macState</c> from it.</summary>
public sealed record PipeHostState
{
    public List<HostShell> Shells { get; init; } = [];
    /// <summary>The account's sign-in name, for <c>host.user</c> (sent to a phone only when it may see the screen).</summary>
    public string? User { get; init; }
    public bool? Locked { get; init; }
    public int? IdleSeconds { get; init; }
    public double? Battery { get; init; }
    public bool? Charging { get; init; }
}
