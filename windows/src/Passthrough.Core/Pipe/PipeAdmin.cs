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
        RevokeSlot = "revokeSlot", Relabel = "relabel", Disconnect = "disconnect", HandOver = "handOver", SetStayAwake = "setStayAwake", Power = "power", Screen = "screen",
        SetMayShare = "setMayShare", Notices = "notices", AnswerNotice = "answerNotice",
        RevokeComputer = "revokeComputer", AllowComputerScreen = "allowComputerScreen";

    public uint Id { get; init; }
    public string Op { get; init; } = "";
    public string? Phone { get; init; }
    public string? Label { get; init; }
    public string? PairingSlot { get; init; }
    /// <summary>A phone's shell key, base64 (<see cref="AddKey"/>).</summary>
    public string? Key { get; init; }
    public bool? On { get; init; }
    /// <summary><see cref="AnswerNotice"/>: which.</summary>
    public string? NoticeId { get; init; }
    /// <summary><see cref="Disconnect"/>: <c>all</c> (its shells and views) or <c>screen</c> (its views only).</summary>
    public string? What { get; init; }
    /// <summary>The access records stage 3 kept in the tray app, moved into the service once (<see cref="HandOver"/>).</summary>
    public List<ShellPhone>? Records { get; init; }
}

public sealed record PipeAdminReply
{
    public const string NotYours = "not_yours", StoreFailed = "store_failed", Unknown = "unknown", BadRequest = "bad_request", NoGrant = "no_grant";

    public uint Id { get; init; }
    public string? Error { get; init; }
    public List<PipeDevice>? Devices { get; init; }
    /// <summary>Computers a phone gave access to this PC (<see cref="PipeAdminRequest.List"/>), as Settings shows them.</summary>
    public List<PipeComputer>? Computers { get; init; }
    public PipeGrant? Grant { get; init; }
    public List<string>? Removed { get; init; }
    public List<string>? Taken { get; init; }
    public List<string>? Kept { get; init; }
    public List<string>? Refused { get; init; }
    /// <summary>Stay awake while plugged in (<see cref="PipeAdminRequest.Power"/>).</summary>
    public bool? StayAwake { get; init; }
    /// <summary>The PC's sleep timer on the current power source, in seconds (0: never).</summary>
    public int? SleepAfter { get; init; }
    public bool? OnMains { get; init; }
    /// <summary>The Screen row for the caller's account (<see cref="PipeAdminRequest.Screen"/>).</summary>
    public PipeScreenRow? ScreenRow { get; init; }
    public List<PipeNotice>? NoticeList { get; init; }
}

/// <summary>Settings' Screen row: <c>host.rdp</c>'s value, the row's state (done, needed, problem), its sentence and its button.</summary>
public sealed record PipeScreenRow(string Rdp, string State, string Text, string? Action, string? Reason);

/// <summary>One phone with access, as Settings shows it.</summary>
public sealed record PipeDevice
{
    public string Phone { get; init; } = "";
    public string Label { get; init; } = "";
    public string PairingSlot { get; init; } = "";
    public bool Screen { get; init; }
    /// <summary>May share access with other computers (stage 7).</summary>
    public bool Share { get; init; }
    public long GrantedAt { get; init; }
    public int Connections { get; init; }
    /// <summary>It is viewing the screen now.</summary>
    public bool Viewing { get; init; }
}

/// <summary>One computer with access to this PC, as Settings shows it (stage 7 a.7).</summary>
public sealed record PipeComputer
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    /// <summary><c>mac</c> or <c>windows</c>, when it said.</summary>
    public string? Kind { get; init; }
    public bool Shell { get; init; }
    /// <summary>It may see the screen now.</summary>
    public bool Screen { get; init; }
    /// <summary>It was given the screen and waits for the owner here (Allow screen).</summary>
    public bool ScreenPending { get; init; }
    /// <summary>The phone that gave it access, by its label.</summary>
    public string GrantedBy { get; init; } = "";
    public long GrantedAt { get; init; }
    public int Connections { get; init; }
    /// <summary>It is viewing the screen now.</summary>
    public bool Viewing { get; init; }
    /// <summary>It was allowed the screen here, but the phone that gave it access has Screen off, so it can't see it now.</summary>
    public bool ScreenHeld { get; init; }
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
    public const string Access = "access", Grant = "grant", Notice = "notice";
    public string What { get; init; } = "";
}

/// <summary>
/// The service's answers to <see cref="PipeAdminRequest"/>s for one account. Pure: the directory, what a grant carries
/// now, and the gate's connections are given.
/// </summary>
public sealed class PipeAdminHandler(AccessDirectory directory, Func<GrantContents?> grant, Func<string, int> connections, Action<string> disconnect, Action<string>? log = null)
{
    /// <summary>Stay awake while plugged in: what it is and the power facts beside it, and setting it (any allowed account, no prompt).</summary>
    public Func<(bool StayAwake, int SleepAfter, bool OnMains)>? PowerState { get; init; }
    public Action<bool>? SetStayAwake { get; init; }

    /// <summary>Ends a phone's views of the screen, keeping its shells, and tells its other connections why (<c>screenEnded</c>).</summary>
    public Action<string, string>? EndScreen { get; init; }

    /// <summary>The notices waiting for each account.</summary>
    public NoticeBoard? Board { get; init; }

    /// <summary>The Screen row for an account; null when this PC has no relay.</summary>
    public Func<string, PipeScreenRow?>? ScreenRow { get; init; }

    /// <summary>Whether a phone or computer is viewing the screen now (the flyout shows it, with Stop).</summary>
    public Func<string, bool>? Viewing { get; init; }

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
                        Phone = p.PhoneId, Label = p.Label, PairingSlot = p.PairingSlot, Screen = p.ScreenAllowed, Share = p.Share == true,
                        GrantedAt = p.GrantedAt.ToUnixTimeSeconds(), Connections = connections(p.PhoneId), Viewing = Viewing?.Invoke(p.PhoneId) == true,
                    })],
                    Computers = [.. directory.ComputersFor(account).All.Select(c => new PipeComputer
                    {
                        Id = c.Id, Name = c.Name, Kind = c.Kind, Shell = c.Shell == true,
                        // What it may do now: its granter's Screen switch counts too.
                        Screen = directory.Computer(c.Id)?.Screen == true, ScreenPending = c.ScreenPending == true,
                        ScreenHeld = c.Screen == true && c.ScreenPending != true && directory.Computer(c.Id)?.Screen != true,
                        GrantedBy = store.Phones.FirstOrDefault(p => p.PhoneId == c.GrantedBy)?.Label ?? "a phone",
                        GrantedAt = c.GrantedAt.ToUnixTimeSeconds(), Connections = connections(c.Id), Viewing = Viewing?.Invoke(c.Id) == true,
                    })],
                };
            case PipeAdminRequest.GrantInfo:
                return grant() is { } contents ? reply with { Grant = PipeGrant.From(contents) } : reply with { Error = PipeAdminReply.NoGrant };
            case PipeAdminRequest.AddKey:
                if (request.Phone is not { } phone || !ShellAccessStore.IsPhoneId(phone) || request.PairingSlot is not { Length: > 0 } slot || Key(request.Key) is not { } key)
                    return reply with { Error = PipeAdminReply.BadRequest };
                var isNew = !store.IsKnown(phone);
                return directory.Add(account, new ShellPhone { PhoneId = phone, Label = ShellAccessStore.CleanLabel(request.Label), PairingSlot = slot, Key = key, GrantedAt = DateTimeOffset.UtcNow }) switch
                {
                    AccessDirectory.AddResult.Added => Welcomed(account, phone, ShellAccessStore.CleanLabel(request.Label), isNew, reply),
                    AccessDirectory.AddResult.NotYours => reply with { Error = PipeAdminReply.NotYours },
                    _ => reply with { Error = PipeAdminReply.StoreFailed },
                };
            case PipeAdminRequest.SetScreen:
                if (request.Phone is not { } screenPhone || request.On is not { } on) return reply with { Error = PipeAdminReply.BadRequest };
                if (!store.IsKnown(screenPhone)) return reply with { Error = PipeAdminReply.Unknown };
                // Off holds in memory even if it can't be written; its views end at once.
                var set = store.SetScreenAllowed(screenPhone, on);
                if (!on)
                {
                    EndScreen?.Invoke(screenPhone, "switched_off");
                    // Its computers' screen goes with its own (their scopes follow it): their views end too.
                    foreach (var c in directory.ComputersFor(account).All.Where(c => c.GrantedBy == screenPhone)) EndScreen?.Invoke(c.Id, "switched_off");
                }
                return set ? reply : reply with { Error = PipeAdminReply.StoreFailed };
            case PipeAdminRequest.SetMayShare:
                if (request.Phone is not { } sharer || request.On is not { } share) return reply with { Error = PipeAdminReply.BadRequest };
                if (!store.IsKnown(sharer)) return reply with { Error = PipeAdminReply.Unknown };
                // Turning it off stops new sharing; computers it already let in stay until removed.
                return store.SetShareAllowed(sharer, share) ? reply : reply with { Error = PipeAdminReply.StoreFailed };
            case PipeAdminRequest.Revoke:
                if (request.Phone is not { } revoked || !store.IsKnown(revoked)) return reply with { Error = PipeAdminReply.Unknown };
                return Removed(account, reply, store.Revoke(revoked));
            case PipeAdminRequest.RevokeSlot:
                if (request.PairingSlot is not { } pairing) return reply with { Error = PipeAdminReply.BadRequest };
                return Removed(account, reply, store.RevokeSlot(pairing));
            case PipeAdminRequest.Relabel:
                if (request.PairingSlot is not { } relabeled) return reply with { Error = PipeAdminReply.BadRequest };
                store.Relabel(relabeled, ShellAccessStore.CleanLabel(request.Label));
                return reply;
            case PipeAdminRequest.Disconnect:
                // A phone of this account, or a computer one of its phones let in (the flyout's Stop works for both).
                if (request.Phone is not { } stopped || !(store.IsKnown(stopped) || directory.ComputersFor(account).Find(stopped) is not null))
                    return reply with { Error = PipeAdminReply.Unknown };
                if (request.What == "screen") EndScreen?.Invoke(stopped, "stopped");
                else disconnect(stopped);
                return reply;
            case PipeAdminRequest.HandOver:
                return HandOver(account, request.Records ?? [], reply);
            case PipeAdminRequest.SetStayAwake:
                if (request.On is not { } awake || SetStayAwake is null) return reply with { Error = PipeAdminReply.BadRequest };
                SetStayAwake(awake);
                return reply;
            case PipeAdminRequest.RevokeComputer:
                if (request.Phone is not { } computerId || !Computers.IsComputerId(computerId)) return reply with { Error = PipeAdminReply.BadRequest };
                var gone = directory.ComputersFor(account).Remove(c => c.Id == computerId);
                if (gone.Count == 0) return reply with { Error = PipeAdminReply.Unknown };
                disconnect(computerId);
                return reply with { Removed = [computerId] };
            case PipeAdminRequest.AllowComputerScreen:
                // On (the default): a screen waiting for the owner is allowed. Off: it waits again, so it can be
                // allowed later, and its views end at once.
                if (request.On == false)
                {
                    if (request.Phone is not { } paused || directory.ComputersFor(account).Find(paused) is not { Screen: true })
                        return reply with { Error = PipeAdminReply.Unknown };
                    var off = directory.ComputersFor(account).SetScreen(paused, on: false, pending: true);
                    EndScreen?.Invoke(paused, "switched_off");
                    return off ? reply : reply with { Error = PipeAdminReply.StoreFailed };
                }
                if (request.Phone is not { } allowed || directory.ComputersFor(account).Find(allowed) is not { ScreenPending: true })
                    return reply with { Error = PipeAdminReply.Unknown };
                return directory.ComputersFor(account).SetScreen(allowed, on: true) ? reply : reply with { Error = PipeAdminReply.StoreFailed };
            case PipeAdminRequest.Notices:
                return reply with { NoticeList = [.. Board?.For(account) ?? []] };
            case PipeAdminRequest.AnswerNotice:
                return request.NoticeId is { } noticeId && Board?.Answer(account, noticeId) == true ? reply : reply with { Error = PipeAdminReply.Unknown };
            case PipeAdminRequest.Screen:
                return reply with { ScreenRow = ScreenRow?.Invoke(account) ?? new PipeScreenRow("service", "problem", "This copy of the service can't relay the screen.", null, null) };
            case PipeAdminRequest.Power:
                if (PowerState?.Invoke() is not { } power) return reply with { Error = PipeAdminReply.BadRequest };
                return reply with { StayAwake = power.StayAwake, SleepAfter = power.SleepAfter, OnMains = power.OnMains };
            default:
                return reply with { Error = PipeAdminReply.BadRequest };
        }
    }

    /// <summary>A phone given access for the first time: the notice that asks whether it may see the screen too.</summary>
    private PipeAdminReply Welcomed(string account, string phone, string label, bool isNew, PipeAdminReply reply)
    {
        if (isNew) Board?.Add(account, PipeNotice.Granted, $"{label} can now open shells on this PC. Let it see the screen too? Windows still asks for your password.", phone);
        return reply;
    }

    /// <summary>
    /// Keys first (a reconnect is already refused), then what is connected and what it opened; and every computer a
    /// removed phone gave access to goes in the same step (its records, its connections, its sessions), so pairing that
    /// phone again brings none back.
    /// </summary>
    private PipeAdminReply Removed(string account, PipeAdminReply reply, (bool Done, IReadOnlyList<ShellPhone> Removed) result)
    {
        foreach (var phone in result.Removed)
        {
            disconnect(phone.PhoneId);
            foreach (var c in directory.ComputersFor(account).Remove(c => c.GrantedBy == phone.PhoneId)) disconnect(c.Id);
        }
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
