using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell.Sessions;

/// <summary>
/// Every session's output, kept on this computer so the owner can review it later (a port of TranscriptStore.swift).
/// Per session: <c>&lt;id&gt;.cast</c> (asciicast v2: output events, and resize events whenever the terminal changes
/// size, and every <see cref="SizeCheckpoint"/> bytes so a tail read finds the size its start was drawn at) and
/// <c>&lt;id&gt;.json</c> (the <see cref="ShellHistoryEntry"/>). Never log what is in them.
/// The folder's access is the caller's: on Windows it lives in the user's profile, whose ACL keeps other accounts out,
/// and the Windows layer tightens it to the owner (the Mac makes it 0700).
/// </summary>
public sealed class TranscriptStore
{
    /// <summary>Most a session's cast file grows to; recording stops there with a marker.</summary>
    public const long DefaultCastLimit = 64L << 20;
    /// <summary>Most output a transcript read returns: the end of the session.</summary>
    public const int ReadLimit = 8 << 20;
    /// <summary>Most the whole folder keeps (<see cref="Prune"/>): past it the oldest finished sessions go.</summary>
    public const long MaxTotalBytes = 2L << 30;
    /// <summary>Most cast bytes between two resize events: past it, the writer restates the size.</summary>
    public const long SizeCheckpoint = 1L << 20;

    internal const int TailBlock = 256 << 10;
    /// <summary>A line longer than this is not one the writer produced; reading stops there.</summary>
    internal const int TailLineLimit = 16 << 20;
    /// <summary>How far past the cut a tail read looks for the size in effect there before taking the header's.</summary>
    internal const int SizeSearchLimit = 2 << 20;
    private static readonly byte[] ResizeMarker = ",\"r\","u8.ToArray();

    internal static readonly JsonSerializerOptions Json = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, // a file, never HTML: keep text as it is
    };

    private readonly string _directory;
    private readonly long _castLimit;
    private readonly long _sizeCheckpoint;
    private readonly Action<string>? _log;
    private readonly Lock _lock = new();
    /// <summary>Held for a whole <see cref="Prune"/>, never by <see cref="Begin"/>.</summary>
    private readonly Lock _pruning = new();
    /// <summary>Writers still recording, so a deletion can stop them from writing again.</summary>
    private Dictionary<string, WeakReference<TranscriptWriter>> _live = [];
    /// <summary>Decoded entries by id, with the .json file's stamp when read, so a listing re-reads only what changed.</summary>
    private Dictionary<string, (FileStamp Stamp, ShellHistoryEntry Entry)> _cached = [];

    private readonly record struct FileStamp(DateTime Modified, long Size);

    /// <summary>Runs in <see cref="Prune"/> once it has seen which sessions are recording, before it reads the folder (tests).</summary>
    internal Action? AfterPruneSnapshot { get; set; }

    /// <param name="castLimit">For tests.</param>
    /// <param name="sizeCheckpoint">For tests.</param>
    public TranscriptStore(string directory, long castLimit = DefaultCastLimit, long sizeCheckpoint = SizeCheckpoint, Action<string>? log = null)
    {
        _directory = directory;
        _castLimit = castLimit;
        _sizeCheckpoint = sizeCheckpoint;
        _log = log;
        Directory.CreateDirectory(directory);
    }

    public string DirectoryPath => _directory;

    public TranscriptWriter Begin(string id, string title, string phoneLabel, int cols, int rows, DateTimeOffset at)
    {
        var castPath = PathFor(id, "cast");
        var jsonPath = PathFor(id, "json");
        // One critical section with DeleteFinished: files exist only once the writer is registered.
        lock (_lock)
        {
            // Clamped like resizes, so the size a replay starts with is always a valid one.
            cols = ShellReplay.Clamp(cols);
            rows = ShellReplay.Clamp(rows);
            var header = JsonSerializer.SerializeToUtf8Bytes(new CastHeader(2, cols, rows, at.ToUnixTimeSeconds(), title), Json);
            var stream = Create(castPath);
            try
            {
                stream.Write(header);
                stream.WriteByte((byte)'\n');
                stream.Flush();
                var entry = new ShellHistoryEntry
                {
                    Id = id, Title = title, PhoneLabel = phoneLabel, StartedAt = Seconds(at), Bytes = 0, Cols = cols, Rows = rows,
                };
                WriteEntry(entry, jsonPath);
                var writer = new TranscriptWriter(stream, entry, jsonPath, header.Length + 1, _castLimit, cols, rows, _sizeCheckpoint, _log);
                _live = _live.Where(p => p.Value.TryGetTarget(out _)).ToDictionary(); // drop sessions long gone
                _live[id] = new WeakReference<TranscriptWriter>(writer);
                return writer;
            }
            catch
            {
                stream.Dispose();
                throw;
            }
        }
    }

    private sealed record CastHeader(
        [property: JsonPropertyName("version")] int Version,
        [property: JsonPropertyName("width")] int Width,
        [property: JsonPropertyName("height")] int Height,
        [property: JsonPropertyName("timestamp")] long Timestamp,
        [property: JsonPropertyName("title")] string Title);

    /// <summary>Newest first. <c>bytes</c> is the cast file's size now, so live sessions are current.</summary>
    public List<ShellHistoryEntry> Entries()
    {
        Dictionary<string, (FileStamp Stamp, ShellHistoryEntry Entry)> known;
        lock (_lock) known = _cached;
        var fresh = new Dictionary<string, (FileStamp Stamp, ShellHistoryEntry Entry)>();
        foreach (var file in SafeFiles("*.json"))
        {
            var id = Path.GetFileNameWithoutExtension(file.Name);
            FileStamp stamp;
            try { file.Refresh(); stamp = new FileStamp(file.LastWriteTimeUtc, file.Length); }
            catch (IOException) { continue; }
            if (known.TryGetValue(id, out var hit) && hit.Stamp == stamp) fresh[id] = hit;
            else if (ReadEntry(file.FullName) is { } entry) fresh[id] = (stamp, entry);
        }
        lock (_lock) _cached = fresh; // removed files drop out here
        return [.. fresh
            .Select(p => p.Value.Entry with { Bytes = Size(Path.Combine(_directory, p.Key + ".cast")) })
            .OrderByDescending(e => e.StartedAt)];
    }

    /// <summary>The end of the session's output, as the bytes the shell wrote: at most <paramref name="maxBytes"/>.</summary>
    public byte[] Output(string id, int maxBytes = ReadLimit) => TailFile(PathFor(id, "cast"), maxBytes).Output;

    /// <summary>
    /// The end of the session (at most <paramref name="maxBytes"/> of output) with the terminal's sizes: first the size
    /// its first byte was drawn at, then output and size changes in order.
    /// </summary>
    public List<ShellReplayChunk> Replay(string id, int maxBytes = ReadLimit) => ReplayFile(PathFor(id, "cast"), maxBytes).Chunks;

    internal static (byte[] Output, int BytesRead) TailFile(string path, int maxBytes)
    {
        var (chunks, bytesRead) = ReplayFile(path, maxBytes);
        using var output = new MemoryStream();
        foreach (var chunk in chunks) if (chunk is ShellReplayChunk.Output o) output.Write(o.Data);
        return (output.ToArray(), bytesRead);
    }

    /// <summary>
    /// <see cref="Replay(string,int)"/> for a cast file, and how many bytes of it were read, reading backwards from the
    /// end a block at a time so a long session never has to fit in memory. Size events' lines count against a budget of
    /// their own, also <paramref name="maxBytes"/>, so a cast of little but resizes is still read only so far.
    /// </summary>
    internal static (List<ShellReplayChunk> Chunks, int BytesRead) ReplayFile(string path, int maxBytes)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var position = file.Length;
        byte[] carry = [];                     // the start of a line whose beginning is in an earlier block
        var pieces = new List<ShellReplayChunk>(); // newest first
        int output = 0, sizes = 0, bytesRead = 0, pastCut = 0;
        (int Cols, int Rows)? startSize = null;
        bool Full() => output >= maxBytes || sizes >= maxBytes;

        void Take(ReadOnlySpan<byte> line)
        {
            if (Full() && line.IndexOf(ResizeMarker) < 0) return;
            if (ParseEvent(line) is not var (code, text)) return;
            switch (code)
            {
                case "o" when !Full():
                    var data = Encoding.UTF8.GetBytes(text);
                    pieces.Add(new ShellReplayChunk.Output(data));
                    output += data.Length;
                    break;
                case "r":
                    if (ShellReplay.ParseSize(text) is not { } size) return;
                    if (Full()) startSize = size;
                    else
                    {
                        pieces.Add(new ShellReplayChunk.Resize(size.Cols, size.Rows));
                        sizes += line.Length;
                        if (Full()) startSize = size; // the oldest piece is a size: it is where the replay starts
                    }
                    break;
            }
        }

        while (position > 0 && startSize is null)
        {
            if (Full() && pastCut > SizeSearchLimit) break;
            var start = Math.Max(0, position - TailBlock);
            var length = (int)(position - start);
            var buffer = new byte[length + carry.Length];
            file.Seek(start, SeekOrigin.Begin);
            file.ReadExactly(buffer, 0, length);
            carry.CopyTo(buffer, length);
            bytesRead += length;
            if (Full()) pastCut += length;
            position = start;
            if (Full() && buffer.AsSpan().IndexOf(ResizeMarker) < 0)
            {
                // No size here: keep only the line that may continue into the previous block.
                var first = Array.IndexOf(buffer, (byte)0x0A);
                carry = buffer[..(first < 0 ? buffer.Length : first)];
                if (carry.Length > TailLineLimit) break;
                continue;
            }
            // Every complete line after the first newline; what precedes it may continue into the previous block.
            var end = buffer.Length;
            while (startSize is null)
            {
                var newline = buffer.AsSpan(0, end).LastIndexOf((byte)0x0A);
                if (newline < 0) break;
                Take(buffer.AsSpan(newline + 1, end - newline - 1));
                end = newline;
            }
            carry = buffer[..end];
            if (carry.Length > TailLineLimit) break;
        }
        // The header's size: the first one, or the fallback when no resize is close enough.
        if (startSize is null)
        {
            var header = position == 0 ? carry : ReadHeader(file);
            if (ParseHeaderSize(header) is { } size) startSize = size;
        }

        var chunks = new List<ShellReplayChunk>();
        if (startSize is { } s) chunks.Add(new ShellReplayChunk.Resize(s.Cols, s.Rows));
        // Oldest first; the oldest piece may be output reaching back past the cut.
        var excess = pieces.Count > 0 && pieces[^1] is ShellReplayChunk.Output ? Math.Max(0, output - maxBytes) : 0;
        var joined = new MemoryStream();
        void Flush()
        {
            if (joined.Length == 0) return;
            chunks.Add(new ShellReplayChunk.Output(joined.ToArray()));
            joined = new MemoryStream();
        }
        for (var i = pieces.Count - 1; i >= 0; i--)
        {
            switch (pieces[i])
            {
                case ShellReplayChunk.Resize r:
                    Flush();
                    // Resizes with no output between them: only the last matters.
                    if (chunks.Count > 0 && chunks[^1] is ShellReplayChunk.Resize) chunks.RemoveAt(chunks.Count - 1);
                    chunks.Add(r);
                    break;
                case ShellReplayChunk.Output o:
                    var data = o.Data.AsSpan();
                    if (excess > 0)
                    {
                        var cut = Math.Min(excess, data.Length);
                        // Start on a character, not inside one.
                        while (cut < data.Length && (data[cut] & 0xC0) == 0x80) cut++;
                        data = data[cut..];
                        excess = 0;
                    }
                    joined.Write(data);
                    break;
            }
        }
        Flush();
        return (chunks, bytesRead);
    }

    /// <summary>One event line: its code and text, or null when it is not <c>[seconds, code, text]</c>.</summary>
    private static (string Code, string Text)? ParseEvent(ReadOnlySpan<byte> line)
    {
        if (line.IsEmpty) return null;
        try
        {
            var reader = new Utf8JsonReader(line);
            using var doc = JsonDocument.ParseValue(ref reader);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Array || root.GetArrayLength() != 3) return null;
            if (root[1].ValueKind != JsonValueKind.String || root[2].ValueKind != JsonValueKind.String) return null;
            return (root[1].GetString()!, root[2].GetString()!);
        }
        catch (JsonException) { return null; }
    }

    private static (int Cols, int Rows)? ParseHeaderSize(ReadOnlySpan<byte> header)
    {
        try
        {
            var reader = new Utf8JsonReader(header);
            using var doc = JsonDocument.ParseValue(ref reader);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("width", out var w) || !w.TryGetInt32(out var cols)) return null;
            if (!root.TryGetProperty("height", out var h) || !h.TryGetInt32(out var rows)) return null;
            return ShellReplay.IsValid(cols, rows) ? (cols, rows) : null;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException) { return null; }
    }

    /// <summary>The cast's first line.</summary>
    private static byte[] ReadHeader(FileStream file)
    {
        file.Seek(0, SeekOrigin.Begin);
        var start = new byte[(int)Math.Min(64 << 10, file.Length)];
        var read = file.ReadAtLeast(start, start.Length, throwOnEndOfStream: false);
        var newline = Array.IndexOf(start, (byte)0x0A, 0, read);
        return start[..(newline < 0 ? read : newline)];
    }

    public void Delete(string id)
    {
        string cast, json;
        try { cast = PathFor(id, "cast"); json = PathFor(id, "json"); }
        catch (ArgumentException) { return; }
        TranscriptWriter? writer = null;
        lock (_lock)
        {
            if (_live.Remove(id, out var weak)) weak.TryGetTarget(out writer);
        }
        writer?.Cancel();
        TryDelete(cast);
        TryDelete(json);
    }

    /// <summary>Deletes every transcript that is not still being recorded. A session just opening has a live writer, so its files stay.</summary>
    public void DeleteFinished()
    {
        lock (_lock)
        {
            var recording = Recording();
            foreach (var file in SafeFiles("*"))
                if (!recording.Contains(Path.GetFileNameWithoutExtension(file.Name))) TryDelete(file.FullName);
            _live = _live.Where(p => recording.Contains(p.Key)).ToDictionary();
            _cached = _cached.Where(p => recording.Contains(p.Key)).ToDictionary();
        }
    }

    /// <summary>
    /// Deletes finished sessions' transcripts: every one that ended before <paramref name="cutoff"/> (null: none for its
    /// age), then, oldest first, as many more as it takes to bring the folder to <paramref name="maxBytes"/>. A session
    /// still being recorded, or just opening, is never deleted. One never seen to end counts as ending when it was last
    /// written. The folder is read outside the lock <see cref="Begin"/> takes, so opening a shell never waits on the
    /// scan; each deletion is checked again under it. Returns how many sessions were deleted.
    /// </summary>
    public int Prune(DateTimeOffset? cutoff, long maxBytes = MaxTotalBytes)
    {
        // One prune at a time, so two never delete on the same stale scan.
        lock (_pruning)
        {
            HashSet<string> recordingAtStart;
            lock (_lock) recordingAtStart = Recording();
            AfterPruneSnapshot?.Invoke();
            long total = 0;
            var finished = new Dictionary<string, Finished>();
            foreach (var file in SafeFiles("*"))
            {
                var ext = file.Extension;
                if (ext is not (".cast" or ".json")) continue;
                long size;
                DateTime modified;
                try { size = file.Length; modified = file.LastWriteTimeUtc; }
                catch (IOException) { continue; }
                total += size;
                var id = Path.GetFileNameWithoutExtension(file.Name);
                if (recordingAtStart.Contains(id)) continue;
                if (!finished.TryGetValue(id, out var item)) finished[id] = item = new Finished();
                item.Files.Add(file.FullName);
                item.Bytes += size;
                var written = new DateTimeOffset(modified, TimeSpan.Zero);
                if (written > item.LastWrite) item.LastWrite = written;
                if (ext == ".json" && ReadEntry(file.FullName)?.EndedAt is { } endedAt)
                    item.Ended = DateTimeOffset.UnixEpoch.AddSeconds(endedAt);
            }
            var deleted = 0;
            // One critical section with Begin, as DeleteFinished: a session opening now waits, one opened is live.
            lock (_lock)
            {
                // Oldest first: once one is neither expired nor needed for room, no later one is.
                foreach (var (id, item) in finished.OrderBy(p => p.Value.Ended ?? p.Value.LastWrite))
                {
                    var expired = cutoff is { } c && (item.Ended ?? item.LastWrite) < c;
                    if (!expired && total <= maxBytes) break;
                    // Begun since the snapshot (its files were scanned as finished): it stays.
                    if (_live.TryGetValue(id, out var weak) && weak.TryGetTarget(out var w) && w.IsRecording) continue;
                    item.Files.ForEach(TryDelete);
                    total -= item.Bytes;
                    _live.Remove(id);
                    _cached.Remove(id);
                    deleted++;
                }
            }
            return deleted;
        }
    }

    private sealed class Finished
    {
        public List<string> Files { get; } = [];
        public long Bytes { get; set; }
        public DateTimeOffset LastWrite { get; set; } = DateTimeOffset.MinValue;
        public DateTimeOffset? Ended { get; set; }
    }

    public void DeleteAll()
    {
        List<TranscriptWriter> writers;
        lock (_lock)
        {
            writers = [.. _live.Values.Select(w => w.TryGetTarget(out var t) ? t : null).OfType<TranscriptWriter>()];
            _live.Clear();
            _cached.Clear();
        }
        writers.ForEach(w => w.Cancel());
        foreach (var file in SafeFiles("*")) TryDelete(file.FullName);
    }

    public long TotalBytes() => SafeFiles("*").Sum(f => { try { return f.Length; } catch (IOException) { return 0L; } });

    /// <summary>Under <c>_lock</c>: ids whose writer still writes.</summary>
    private HashSet<string> Recording() =>
        [.. _live.Where(p => p.Value.TryGetTarget(out var w) && w.IsRecording).Select(p => p.Key)];

    /// <summary>Ids are opaque, but they become file names: nothing that can leave the folder or name a device.</summary>
    private string PathFor(string id, string ext)
    {
        if (!IsSafeId(id)) throw new ArgumentException("not a session id", nameof(id));
        return Path.Combine(_directory, $"{id}.{ext}");
    }

    /// <summary>
    /// Letters, digits, '-', '_' and '.', not starting with a dot, at most 128: the Mac's rule (no '/', no '..') and
    /// what Windows adds (no '\', ':', a drive, a device name such as <c>CON</c>, or trailing dots and spaces).
    /// </summary>
    internal static bool IsSafeId(string id)
    {
        if (id.Length is 0 or > 128 || id[0] == '.' || id[^1] == '.' || id.Contains("..", StringComparison.Ordinal)) return false;
        if (!id.All(c => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_' or '.')) return false;
        var stem = id.Split('.')[0].ToUpperInvariant();
        return stem is not ("CON" or "PRN" or "AUX" or "NUL")
            && !(stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && char.IsDigit(stem[3]));
    }

    private IEnumerable<FileInfo> SafeFiles(string pattern)
    {
        try { return new DirectoryInfo(_directory).GetFiles(pattern); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    private static long Size(string path)
    {
        try { return new FileInfo(path).Length; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return 0; }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    internal static double Seconds(DateTimeOffset at) => (at - DateTimeOffset.UnixEpoch).TotalSeconds;

    /// <summary>Truncating any earlier file; others may read it, and a deletion need not wait for it to close.</summary>
    internal static FileStream Create(string path) =>
        new(path, FileMode.Create, FileAccess.Write, FileShare.Read | FileShare.Delete);

    internal static void WriteEntry(ShellHistoryEntry entry, string path)
    {
        using var stream = Create(path);
        JsonSerializer.Serialize(stream, entry, Json);
    }

    private static ShellHistoryEntry? ReadEntry(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return JsonSerializer.Deserialize<ShellHistoryEntry>(stream, Json);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }
}

/// <summary>Appends one session's output to its cast file. Safe to call from any thread.</summary>
public sealed class TranscriptWriter
{
    /// <summary>What ends a cast that reached its limit.</summary>
    internal const string TruncationMarker = "\r\n[transcript truncated]\r\n";
    /// <summary>Room kept below the limit for the marker's event line.</summary>
    private const long MarkerReserve = 128;

    private readonly Lock _lock = new();
    private FileStream? _stream;
    private ShellHistoryEntry _entry;
    private readonly string _jsonPath;
    /// <summary>An incomplete UTF-8 sequence at the end of the last chunk (at most 3 bytes).</summary>
    private byte[] _pending = [];
    private bool _cancelled;
    /// <summary>The cast file's size so far, and the most it may reach.</summary>
    private long _written;
    private readonly long _limit;
    /// <summary>The limit was reached: the marker is written and nothing more is.</summary>
    private bool _truncated;
    private int _cols, _rows;
    private long _sizeWrittenAt;
    private readonly long _checkpoint;
    private readonly Action<string>? _log;

    internal TranscriptWriter(FileStream stream, ShellHistoryEntry entry, string jsonPath, long written, long limit,
        int cols, int rows, long checkpoint, Action<string>? log)
    {
        _stream = stream; _entry = entry; _jsonPath = jsonPath; _written = written; _limit = limit;
        _cols = cols; _rows = rows; _sizeWrittenAt = written; _checkpoint = checkpoint; _log = log;
    }

    /// <summary>
    /// The terminal changed size: a resize event (asciicast v2 <c>"r"</c>), so a replay draws what follows at the width
    /// the shell drew it for. Output held back as an incomplete character stays held: it continues after.
    /// </summary>
    public void Resize(int cols, int rows, DateTimeOffset at)
    {
        lock (_lock)
        {
            cols = ShellReplay.Clamp(cols);
            rows = ShellReplay.Clamp(rows);
            if (_stream is null || _truncated || (cols == _cols && rows == _rows)) return;
            _cols = cols;
            _rows = rows;
            WriteSize(at);
        }
    }

    public void Append(ReadOnlySpan<byte> data, DateTimeOffset at)
    {
        lock (_lock)
        {
            if (_stream is null || _truncated) return;
            var bytes = new byte[_pending.Length + data.Length];
            _pending.CopyTo(bytes, 0);
            data.CopyTo(bytes.AsSpan(_pending.Length));
            var keep = IncompleteTailLength(bytes);
            _pending = bytes[^keep..];
            Write(bytes.AsSpan(0, bytes.Length - keep), at);
        }
    }

    /// <summary>Still writing: neither finished nor deleted.</summary>
    internal bool IsRecording { get { lock (_lock) return _stream is not null && !_cancelled; } }

    /// <summary>The session was deleted: stop writing and recreate nothing.</summary>
    internal void Cancel()
    {
        lock (_lock)
        {
            _stream?.Dispose();
            _stream = null;
            _cancelled = true;
        }
    }

    /// <summary>The title is only known once the first command is typed; the cast header keeps its original.</summary>
    public void SetTitle(string title)
    {
        lock (_lock)
        {
            if (_cancelled) return;
            _entry = _entry with { Title = title };
            TryWriteEntry();
        }
    }

    public void Finish(int? exitStatus, DateTimeOffset at)
    {
        lock (_lock)
        {
            if (_stream is null || _cancelled) return;
            Write(_pending, at);
            _pending = [];
            _stream.Dispose();
            _stream = null;
            _entry = _entry with { EndedAt = TranscriptStore.Seconds(at), ExitStatus = exitStatus, Bytes = _written };
            TryWriteEntry();
        }
    }

    private void TryWriteEntry()
    {
        try { TranscriptStore.WriteEntry(_entry, _jsonPath); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>One output event, after restating the size if the last statement is <c>checkpoint</c> bytes back.</summary>
    private void Write(ReadOnlySpan<byte> bytes, DateTimeOffset at)
    {
        if (bytes.IsEmpty || _truncated) return;
        if (_written - _sizeWrittenAt >= _checkpoint) WriteSize(at);
        Record("o", Encoding.UTF8.GetString(bytes), at);
    }

    private void WriteSize(DateTimeOffset at)
    {
        Record("r", ShellReplay.SizeString(_cols, _rows), at);
        _sizeWrittenAt = _written;
    }

    /// <summary>Appends one event line. Past the limit, the marker goes in instead and recording stops; the session carries on.</summary>
    private void Record(string code, string text, DateTimeOffset at)
    {
        if (_truncated) return;
        var line = EventLine(code, text, at);
        if (_written + line.Length > _limit - MarkerReserve)
        {
            _truncated = true;
            _pending = [];
            AppendLine(EventLine("o", TruncationMarker, at));
            _log?.Invoke("shell: a session's transcript reached its size limit; recording stopped");
            return;
        }
        AppendLine(line);
    }

    private byte[] EventLine(string code, string text, DateTimeOffset at)
    {
        var seconds = Math.Max(0, TranscriptStore.Seconds(at) - _entry.StartedAt);
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, new JsonWriterOptions { Encoder = TranscriptStore.Json.Encoder }))
        {
            json.WriteStartArray();
            json.WriteNumberValue(seconds);
            json.WriteStringValue(code);
            json.WriteStringValue(text);
            json.WriteEndArray();
        }
        buffer.WriteByte((byte)'\n');
        return buffer.ToArray();
    }

    private void AppendLine(byte[] line)
    {
        if (_stream is null) return;
        try
        {
            _stream.Write(line);
            _stream.Flush();
            _written += line.Length;
        }
        catch (IOException) { }
    }

    /// <summary>How many bytes at the end begin a multi-byte sequence the next chunk completes.</summary>
    internal static int IncompleteTailLength(ReadOnlySpan<byte> bytes)
    {
        for (var back = 1; back <= Math.Min(3, bytes.Length); back++)
        {
            var b = bytes[^back];
            if ((b & 0xC0) == 0x80) continue; // continuation: keep looking for the lead
            var needed = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1;
            return needed > back ? back : 0;
        }
        return 0;
    }
}
