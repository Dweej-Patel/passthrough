using System.Text;

namespace Passthrough.Core.Shell.Sessions;

/// <summary>
/// OSC 7501, the Program Status Protocol, read from a session's output (a port of ProgramStatus.swift): a program that
/// speaks it (Claude Code does) says whether it is working, blocked on the user (and why), done, idle or failed. It
/// asks first (<c>ESC ] 7501 ; ?</c>, with BEL or ST, then the device attributes), and the host answers for every
/// terminal a session is shown in. From then on it sends reports, <c>ESC ] 7501 ; key=value:key=value… ST</c>; each
/// replaces a record: the root (no <c>id</c>) is the program, and each of its agents has its own.
/// https://mitchellh.com/writing/program-status-osc7501 (spec 0.4). Not thread-safe.
/// </summary>
internal sealed class ProgramStatus
{
    /// <summary>What a terminal that supports the protocol answers the query with.</summary>
    public static readonly byte[] SupportReply =
        Encoding.ASCII.GetBytes("\u001b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u001b\\");

    public sealed record Record(string State, string? Kind = null, string? Message = null, string? Title = null);

    public readonly record struct Summary(string State, string? Kind, string? Message, int Agents);

    [Flags]
    public enum Outcome { None = 0, Queried = 1, Changed = 2 }

    internal const string Clear = "clear";
    internal static readonly IReadOnlySet<string> States = new HashSet<string>
        { ShellStatus.Idle, ShellStatus.Working, ShellStatus.Done, ShellStatus.Blocked, ShellStatus.Failed, Clear };
    internal static readonly IReadOnlySet<string> Kinds = new HashSet<string> { "permission", "question", "auth" };
    internal const int MaxSequence = 4096;
    internal const int MaxRecords = 256;
    internal const int MaxMessageBytes = 2048;
    internal const int MaxTitleBytes = 192;
    private static readonly byte[] Prefix = "7501;"u8.ToArray();

    private enum State { Ground, Escape, Osc, OscEscape, Skipping, SkippingEscape }

    private readonly Dictionary<string, Record> _records = [];
    private State _state = State.Ground;
    private readonly List<byte> _body = [];

    /// <summary>By id; the root under "".</summary>
    public IReadOnlyDictionary<string, Record> Records => _records;

    public bool IsEmpty => _records.Count == 0;

    /// <summary>Reads a chunk of output; <paramref name="summaries"/>, when given, gets the summary after each change.</summary>
    public Outcome Scan(ReadOnlySpan<byte> data, List<Summary?>? summaries = null)
    {
        var outcome = Outcome.None;
        var i = 0;
        while (i < data.Length)
        {
            if (_state == State.Ground)
            {
                var escape = data[i..].IndexOf((byte)0x1B);
                if (escape < 0) break;
                i += escape;
            }
            var step = Step(data[i]);
            if (step.HasFlag(Outcome.Changed)) summaries?.Add(CurrentSummary);
            outcome |= step;
            i++;
        }
        return outcome;
    }

    /// <summary>The program that reported went away without clearing its records: nothing it said describes the session any more.</summary>
    public bool ForgetAll()
    {
        if (_records.Count == 0) return false;
        _records.Clear();
        return true;
    }

    private static bool IsUnfinished(Record r) => r.State is ShellStatus.Working or ShellStatus.Blocked;

    /// <summary>
    /// What the session as a whole is doing. Blocked anywhere is blocked (the root's question first); otherwise working
    /// while the root or any agent still is; otherwise the root's own state. Null without records.
    /// </summary>
    public Summary? CurrentSummary
    {
        get
        {
            if (_records.Count == 0) return null;
            _records.TryGetValue("", out var root);
            var agents = _records.Where(p => p.Key.Length > 0 && IsUnfinished(p.Value)).OrderBy(p => p.Key, StringComparer.Ordinal).ToList();
            if (root?.State == ShellStatus.Blocked) return new(ShellStatus.Blocked, root.Kind, root.Message, agents.Count);
            if (agents.FirstOrDefault(p => p.Value.State == ShellStatus.Blocked) is { Value: { } agent })
            {
                var message = string.Join(": ", new[] { agent.Title, agent.Message }.OfType<string>());
                return new(ShellStatus.Blocked, agent.Kind, message.Length == 0 ? null : message, agents.Count);
            }
            if (root?.State == ShellStatus.Working || agents.Count > 0) return new(ShellStatus.Working, null, root?.Message, agents.Count);
            return root is null ? null : new(root.State, null, root.Message, 0);
        }
    }

    private Outcome Step(byte b)
    {
        switch (_state)
        {
            case State.Ground:
                if (b == 0x1B) _state = State.Escape;
                break;
            case State.Escape:
                switch (b)
                {
                    case (byte)']': _state = State.Osc; _body.Clear(); break;
                    case (byte)'c':
                        // A full reset ends every record.
                        _state = State.Ground;
                        if (_records.Count > 0) { _records.Clear(); return Outcome.Changed; }
                        break;
                    case 0x1B: break;
                    default: _state = State.Ground; break;
                }
                break;
            case State.Osc:
                switch (b)
                {
                    case 0x07: _state = State.Ground; return Finish();
                    case 0x1B: _state = State.OscEscape; break;
                    case 0x18 or 0x1A: _state = State.Ground; break;
                    default:
                        _body.Add(b);
                        // Not this protocol, or too long to be a report: skip the rest of it.
                        if (_body.Count == Prefix.Length && !_body.SequenceEqual(Prefix)) _state = State.Skipping;
                        if (_body.Count > MaxSequence) _state = State.Skipping;
                        break;
                }
                break;
            case State.OscEscape:
                // ESC \ ends it; any other escape ends it too and begins a sequence.
                if (b == (byte)'\\') { _state = State.Ground; return Finish(); }
                var outcome = Finish();
                _state = State.Escape;
                return outcome | Step(b);
            case State.Skipping:
                if (b is 0x07 or 0x18 or 0x1A) _state = State.Ground;
                else if (b == 0x1B) _state = State.SkippingEscape;
                break;
            case State.SkippingEscape:
                if (b == (byte)'\\') _state = State.Ground;
                else { _state = State.Escape; return Step(b); }
                break;
        }
        return Outcome.None;
    }

    private Outcome Finish()
    {
        if (_body.Count < Prefix.Length || !_body.Take(Prefix.Length).SequenceEqual(Prefix)) return Outcome.None;
        var text = Encoding.UTF8.GetString([.. _body.Skip(Prefix.Length)]);
        if (text == "?") return Outcome.Queried;
        return Apply(text) ? Outcome.Changed : Outcome.None;
    }

    /// <summary>One report: replaces its record (or clears records). A malformed one is ignored whole.</summary>
    private bool Apply(string text)
    {
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in text.Split(':', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            if (eq < 0) continue;
            fields[pair[..eq]] = pair[(eq + 1)..];
        }
        if (!fields.TryGetValue("state", out var state) || !States.Contains(state)) return false;
        var id = fields.GetValueOrDefault("id", "");
        if (id.Length > 0 && !IsValidId(id)) return false;
        if (state == Clear)
        {
            var before = _records.Count;
            if (id.Length == 0) _records.Clear();
            else foreach (var key in _records.Keys.Where(k => k == id || k.StartsWith(id + "/", StringComparison.Ordinal)).ToList()) _records.Remove(key);
            return _records.Count != before;
        }
        string? kind = state == ShellStatus.Blocked && fields.TryGetValue("kind", out var k) && Kinds.Contains(k) ? k : null;
        string? message = null, title = null;
        if (fields.TryGetValue("msg", out var m) && (message = Text(m, MaxMessageBytes)) is null) return false;
        if (fields.TryGetValue("title", out var t) && (title = Text(t, MaxTitleBytes)) is null) return false;
        var record = new Record(state, kind, message, title);
        if (_records.TryGetValue(id, out var existing) && existing == record) return false;
        if (existing is null && _records.Count >= MaxRecords) return false;
        _records[id] = record;
        return true;
    }

    /// <summary>Base64 UTF-8 without control characters, or null.</summary>
    private static string? Text(string base64, int limit)
    {
        byte[] data;
        try { data = Convert.FromBase64String(base64); }
        catch (FormatException) { return null; }
        if (data.Length > limit) return null;
        string text;
        try { text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(data); }
        catch (ArgumentException) { return null; }
        return text.Any(c => c < 0x20 || c == 0x7F) ? null : text;
    }

    /// <summary><c>seg/seg/…</c>: up to 8 segments of 1–32 of <c>A–Z a–z 0–9 _ . + -</c>, 128 characters in all.</summary>
    private static bool IsValidId(string id)
    {
        if (Encoding.UTF8.GetByteCount(id) > 128) return false;
        var segments = id.Split('/');
        return segments.Length <= 8 && segments.All(s => s.Length is >= 1 and <= 32
            && s.All(c => c is >= '0' and <= '9' or >= 'A' and <= 'Z' or >= 'a' and <= 'z' or '_' or '.' or '+' or '-'));
    }
}
