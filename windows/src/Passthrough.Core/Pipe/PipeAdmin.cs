using System.Text.Json.Serialization;
using Passthrough.Core.Shell.Access;

namespace Passthrough.Core.Pipe;

/// <summary>
/// The tray app's requests about its account's phones (<see cref="PipeKind.Admin"/>, stage 4 plan, section 4's op
/// table). Every op acts only on the caller's account, which the service knows from the pipe's token.
/// </summary>
public sealed record PipeAdminRequest
{
    public const string List = "list", GrantInfo = "grantInfo", AddKey = "addKey", SetScreen = "setScreen", Revoke = "revoke",
        RevokeSlot = "revokeSlot", Relabel = "relabel", Disconnect = "disconnect", HandOver = "handOver";

    public uint Id { get; init; }
    public string Op { get; init; } = "";
    public string? Phone { get; init; }
    public string? Label { get; init; }
    public string? PairingSlot { get; init; }
    /// <summary>A phone's shell key, base64 (<see cref="AddKey"/>).</summary>
    public string? Key { get; init; }
    public bool? On { get; init; }
    /// <summary>The access records stage 3 kept in the tray app, moved into the service once (<see cref="HandOver"/>).</summary>
    public List<ShellPhone>? Records { get; init; }
}

public sealed record PipeAdminReply
{
    public const string NotYours = "not_yours", StoreFailed = "store_failed", Unknown = "unknown", BadRequest = "bad_request", NoGrant = "no_grant";

    public uint Id { get; init; }
    public string? Error { get; init; }
    public List<PipeDevice>? Devices { get; init; }
    public PipeGrant? Grant { get; init; }
    public List<string>? Removed { get; init; }
    public List<string>? Taken { get; init; }
    public List<string>? Kept { get; init; }
    public List<string>? Refused { get; init; }
}

/// <summary>One phone with access, as Settings shows it.</summary>
public sealed record PipeDevice
{
    public string Phone { get; init; } = "";
    public string Label { get; init; } = "";
    public string PairingSlot { get; init; } = "";
    public bool Screen { get; init; }
    public long GrantedAt { get; init; }
    public int Connections { get; init; }
}

/// <summary>What a grant carries now (<see cref="GrantContents"/> across the pipe).</summary>
public sealed record PipeGrant
{
    public string CertSHA256 { get; init; } = "";
    public int Port { get; init; }
    public List<string> Addresses { get; init; } = [];
    public string HostName { get; init; } = "";
    public string? IrohId { get; init; }
    public string? IrohRelay { get; init; }
    [JsonPropertyName("relayToken")] public string? RelayToken { get; init; }

    public static PipeGrant From(GrantContents g) => new()
    {
        CertSHA256 = g.CertSHA256, Port = g.Port, Addresses = [.. g.Addresses], HostName = g.HostName, IrohId = g.IrohId, IrohRelay = g.IrohRelay, RelayToken = g.RelayToken,
    };

    public GrantContents ToContents() => new()
    {
        CertSHA256 = CertSHA256, Port = Port, Addresses = Addresses, HostName = HostName, IrohId = IrohId, IrohRelay = IrohRelay, RelayToken = RelayToken,
    };
}

/// <summary>An event the service pushes (<see cref="PipeKind.AdminEvent"/>): <c>access</c> (the phones changed), <c>grant</c> (what a grant carries changed).</summary>
public sealed record PipeAdminEvent
{
    public const string Access = "access", Grant = "grant";
    public string What { get; init; } = "";
}

/// <summary>
/// The service's answers to <see cref="PipeAdminRequest"/>s for one account. Pure: the directory, what a grant carries
/// now, and the gate's connections are given.
/// </summary>
public sealed class PipeAdminHandler(AccessDirectory directory, Func<GrantContents?> grant, Func<string, int> connections, Action<string> disconnect, Action<string>? log = null)
{
    public PipeAdminReply Handle(string account, PipeAdminRequest request)
    {
        var store = directory.For(account);
        var reply = new PipeAdminReply { Id = request.Id };
        switch (request.Op)
        {
            case PipeAdminRequest.List:
                return reply with
                {
                    Devices = [.. store.Phones.Select(p => new PipeDevice
                    {
                        Phone = p.PhoneId, Label = p.Label, PairingSlot = p.PairingSlot, Screen = p.ScreenAllowed,
                        GrantedAt = p.GrantedAt.ToUnixTimeSeconds(), Connections = connections(p.PhoneId),
                    })],
                };
            case PipeAdminRequest.GrantInfo:
                return grant() is { } contents ? reply with { Grant = PipeGrant.From(contents) } : reply with { Error = PipeAdminReply.NoGrant };
            case PipeAdminRequest.AddKey:
                if (request.Phone is not { } phone || !ShellAccessStore.IsPhoneId(phone) || request.PairingSlot is not { Length: > 0 } slot || Key(request.Key) is not { } key)
                    return reply with { Error = PipeAdminReply.BadRequest };
                return directory.Add(account, new ShellPhone { PhoneId = phone, Label = ShellAccessStore.CleanLabel(request.Label), PairingSlot = slot, Key = key, GrantedAt = DateTimeOffset.UtcNow }) switch
                {
                    AccessDirectory.AddResult.Added => reply,
                    AccessDirectory.AddResult.NotYours => reply with { Error = PipeAdminReply.NotYours },
                    _ => reply with { Error = PipeAdminReply.StoreFailed },
                };
            case PipeAdminRequest.SetScreen:
                if (request.Phone is not { } screenPhone || request.On is not { } on) return reply with { Error = PipeAdminReply.BadRequest };
                if (!store.IsKnown(screenPhone)) return reply with { Error = PipeAdminReply.Unknown };
                return store.SetScreenAllowed(screenPhone, on) ? reply : reply with { Error = PipeAdminReply.StoreFailed };
            case PipeAdminRequest.Revoke:
                if (request.Phone is not { } revoked || !store.IsKnown(revoked)) return reply with { Error = PipeAdminReply.Unknown };
                return Removed(reply, store.Revoke(revoked));
            case PipeAdminRequest.RevokeSlot:
                if (request.PairingSlot is not { } pairing) return reply with { Error = PipeAdminReply.BadRequest };
                return Removed(reply, store.RevokeSlot(pairing));
            case PipeAdminRequest.Relabel:
                if (request.PairingSlot is not { } relabeled) return reply with { Error = PipeAdminReply.BadRequest };
                store.Relabel(relabeled, ShellAccessStore.CleanLabel(request.Label));
                return reply;
            case PipeAdminRequest.Disconnect:
                if (request.Phone is not { } stopped || !store.IsKnown(stopped)) return reply with { Error = PipeAdminReply.Unknown };
                disconnect(stopped);
                return reply;
            case PipeAdminRequest.HandOver:
                return HandOver(account, request.Records ?? [], reply);
            default:
                return reply with { Error = PipeAdminReply.BadRequest };
        }
    }

    /// <summary>Keys first (a reconnect is already refused), then what is connected and what it opened.</summary>
    private PipeAdminReply Removed(PipeAdminReply reply, (bool Done, IReadOnlyList<ShellPhone> Removed) result)
    {
        foreach (var phone in result.Removed) disconnect(phone.PhoneId);
        return result.Done ? reply with { Removed = [.. result.Removed.Select(p => p.PhoneId)] } : reply with { Error = PipeAdminReply.StoreFailed };
    }

    /// <summary>
    /// Stage 3's records, moved in once (RECONCILIATION: records only; the service has keys of its own). Each is
    /// <c>kept</c> when this account already has the phone, <c>refused</c> when another account does, else <c>taken</c>.
    /// </summary>
    private PipeAdminReply HandOver(string account, List<ShellPhone> records, PipeAdminReply reply)
    {
        var store = directory.For(account);
        List<string> taken = [], kept = [], refused = [];
        foreach (var record in records)
        {
            if (!ShellAccessStore.IsPhoneId(record.PhoneId) || record.Key.Length < Shell.RemoteShell.KeyLength) { refused.Add(record.PhoneId); continue; }
            if (store.IsKnown(record.PhoneId)) { kept.Add(record.PhoneId); continue; }
            switch (directory.Add(account, record with { Label = ShellAccessStore.CleanLabel(record.Label) }))
            {
                case AccessDirectory.AddResult.Added: taken.Add(record.PhoneId); break;
                case AccessDirectory.AddResult.NotYours: refused.Add(record.PhoneId); break;
                default: return reply with { Error = PipeAdminReply.StoreFailed };
            }
        }
        log?.Invoke($"access: took {taken.Count}, kept {kept.Count}, refused {refused.Count} phone record(s) handed over");
        return reply with { Taken = taken, Kept = kept, Refused = refused };
    }

    private static byte[]? Key(string? base64)
    {
        try { return base64 is null ? null : Convert.FromBase64String(base64) is { Length: Shell.RemoteShell.KeyLength } key ? key : null; }
        catch (FormatException) { return null; }
    }
}
