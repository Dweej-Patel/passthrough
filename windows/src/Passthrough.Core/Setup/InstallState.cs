using System.Text.Json;
using System.Text.Json.Serialization;

namespace Passthrough.Core.Setup;

/// <summary>
/// <c>%ProgramData%\Passthrough\install.json</c> (stage 4 plan, section 3): what the elevated verbs did, so a later run
/// can undo exactly that. The service reads it and can't write it. The relay token is never here (it is a secret).
/// </summary>
public sealed record InstallState
{
    public const int CurrentVersion = 1;

    public int StateVersion { get; init; } = CurrentVersion;
    public long InstalledAt { get; init; }
    public string Build { get; init; } = "";
    public string InstallFolder { get; init; } = "";
    /// <summary>The Windows accounts (SIDs) that may use the service, at most <see cref="ServiceDefinition.MaxAccounts"/>.</summary>
    public IReadOnlyList<string> AllowedAccounts { get; init; } = [];
    public CreatedThings Created { get; init; } = new();
    public IReadOnlyList<string> FirewallRules { get; init; } = [];
    /// <summary>Install folders that were in use when replaced, queued for deletion at the next restart.</summary>
    public IReadOnlyList<string> StaleFolders { get; init; } = [];
    public RelayState Relay { get; init; } = new();
    /// <summary>Screen (stage 5): the mode, who consented, and what Remote Desktop was before Passthrough changed it; null when not set up.</summary>
    public Screen.RemoteDesktopSetup? Rdp { get; init; }

    public sealed record CreatedThings
    {
        public bool DataFolder { get; init; }
        public bool ProgramFolder { get; init; }
        public bool Service { get; init; }
        public bool Shortcut { get; init; }
    }

    public sealed record RelayState
    {
        public string? Url { get; init; }
    }

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    public byte[] Encode() => JsonSerializer.SerializeToUtf8Bytes(this, Options);

    /// <summary>The state, or null for anything unreadable or from a newer build.</summary>
    public static InstallState? Decode(byte[] bytes)
    {
        try
        {
            var state = JsonSerializer.Deserialize<InstallState>(bytes, Options);
            return state is { StateVersion: <= CurrentVersion } ? state : null;
        }
        catch (JsonException) { return null; }
    }

    /// <summary>With <paramref name="sid"/> allowed (first in, first kept; at most <see cref="ServiceDefinition.MaxAccounts"/>).</summary>
    public InstallState Allowing(string sid)
    {
        if (AllowedAccounts.Contains(sid, StringComparer.OrdinalIgnoreCase)) return this;
        if (AllowedAccounts.Count >= ServiceDefinition.MaxAccounts)
            throw new SetupException($"Remote access on this PC is already set up for {ServiceDefinition.MaxAccounts} accounts. Remove one first.");
        return this with { AllowedAccounts = [.. AllowedAccounts, sid] };
    }
}
