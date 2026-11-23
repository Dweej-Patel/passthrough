namespace Passthrough.Core.ClipSync;

public abstract record ClipEvent
{
    /// <summary>The other side finished sending a transfer: it's complete and checked. Answer with <see cref="ClipSyncSession.Result"/>.</summary>
    public sealed record Received(ReceivedTransfer Transfer) : ClipEvent;
    /// <summary>The other side won't take one of ours, or it couldn't be read here (<see cref="ClipDecline.Failed"/>).</summary>
    public sealed record Declined(uint Transfer, ClipDecline Reason) : ClipEvent;
    /// <summary>What the other side did with one of ours.</summary>
    public sealed record Outcome(uint Transfer, ClipResult Status) : ClipEvent;
    /// <summary>All of one of ours has gone out.</summary>
    public sealed record Sent(uint Transfer) : ClipEvent;
    /// <summary>The other side began sending one: <paramref name="Total"/> bytes are coming, for (<paramref name="X"/>, <paramref name="Y"/>) when it's a drop.</summary>
    public sealed record Incoming(uint Transfer, ClipKind Kind, ulong Total, ushort X, ushort Y) : ClipEvent;
    /// <summary>The other side stopped sending one, or it failed here.</summary>
    public sealed record IncomingEnded(uint Transfer) : ClipEvent;
    /// <summary>The stream ended (null: <see cref="ClipSyncSession.Close"/>, or the other side closed it cleanly).</summary>
    public sealed record Closed(Exception? Error) : ClipEvent;
}

public sealed class ClipSyncOptions
{
    /// <summary>Where the other side's files go, one folder per transfer.</summary>
    public required string Staging { get; init; }

    /// <summary>A host takes its viewers' drops; a viewer takes none from its host (declined at the offer, 4).</summary>
    public bool AcceptDrops { get; init; }

    /// <summary>Bytes free for received files (null: unknown, and then no drop is taken). Unset: the staging folder's drive, less 1 GiB.</summary>
    public Func<ulong?>? Room { get; init; }

    /// <summary>
    /// Opens a file to send. Unset: an ordinary open. A PC opens the file itself and never what a link put in its
    /// place since it was listed (<c>FILE_FLAG_OPEN_REPARSE_POINT</c>, then a check that it is a plain file).
    /// </summary>
    public Func<string, FileStream>? OpenToSend { get; init; }

    /// <summary>Told each received file once it is whole and closed (a PC marks it as from another computer, so Windows warns before running it).</summary>
    public Action<string>? FileReceived { get; init; }

    /// <summary>One part of a received name as this file system can hold it (<see cref="ClipNames.WindowsPart"/> on a PC).</summary>
    public Func<string, string> LocalPart { get; init; } = ClipNames.WindowsPart;
}

/// <summary>
/// One side of clipboard sync over a stream (protocol/README.md, "Clipboard sync"; a port of ClipSyncSession.swift),
/// the same for a host and a viewer. It sends transfers only as fast as the stream takes them (each write is awaited,
/// so nothing queues but small control messages), takes the other side's into folders under
/// <see cref="ClipSyncOptions.Staging"/> as the bytes arrive, and says what happened through the callback, in order,
/// from its own tasks.
/// </summary>
public sealed class ClipSyncSession
{
    private readonly Stream _stream;
    private readonly ReadOnlyMemory<byte> _initial;
    private readonly ClipSyncOptions _options;
    private readonly Action<ClipEvent> _onEvent;
    private readonly CancellationTokenSource _closing = new();
    private readonly Lock _lock = new();
    private readonly SemaphoreSlim _wake = new(0);
    private int _closed;
    private int _started;

    // Sending
    private readonly Queue<byte[]> _control = new();
    private readonly List<Outgoing> _outgoing = [];
    private uint _nextTransfer = 1;

    // Receiving (the reader's task only)
    private readonly Dictionary<uint, Incoming> _incoming = [];
    private uint _lastOffer;

    public ClipSyncSession(Stream stream, ReadOnlyMemory<byte> initialBytes, ClipSyncOptions options, Action<ClipEvent> onEvent)
    {
        _stream = stream;
        _initial = initialBytes;
        _options = options;
        _onEvent = onEvent;
    }

    public bool IsClosed => Volatile.Read(ref _closed) == 1;

    /// <summary>Says hello, then sends and receives until the stream ends or <see cref="Close"/>; <see cref="ClipEvent.Closed"/> is the last event.</summary>
    public async Task RunAsync()
    {
        if (Interlocked.Exchange(ref _started, 1) == 1) return;
        Exception? error = null;
        var writer = Task.Run(WriteAllAsync);
        try
        {
            var reader = new ClipSyncWire.Reader(_initial.IsEmpty ? _stream : new PrefixedStream(_initial, _stream));
            while (await reader.ReadAsync(_closing.Token).ConfigureAwait(false) is { } message)
                await HandleAsync(message).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException) { error = IsClosed ? null : e; }
        Close();
        try { error ??= await writer.ConfigureAwait(false); }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { }
        foreach (var t in _incoming.Values) Discard(t);
        _incoming.Clear();
        Emit(new ClipEvent.Closed(error));
    }

    /// <summary>Ends the session and closes the stream. Idempotent.</summary>
    public void Close()
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        _closing.Cancel();
        try { _stream.Dispose(); }
        catch (Exception e) when (e is IOException or ObjectDisposedException) { }
        _wake.Release();
    }

    // MARK: Sending

    private sealed class Outgoing(ClipOffer offer, IReadOnlyList<ClipItem> items)
    {
        public readonly ClipOffer Offer = offer;
        public readonly IReadOnlyList<ClipItem> Items = items;
        public bool OfferSent;
        /// <summary>Replaced, or declined by the other side: nothing more of it is sent.</summary>
        public volatile bool Gone;
        public int Index;
        public bool Announced;
        public ulong SentOfItem;
        public FileStream? File;
    }

    /// <summary>
    /// Starts sending <paramref name="payload"/> and returns its transfer number. A clipboard transfer abandons this
    /// side's previous unfinished one, never a drop.
    /// </summary>
    public uint Send(ClipPayload payload, ClipKind kind, ushort x = 0, ushort y = 0)
    {
        uint id;
        lock (_lock)
        {
            id = _nextTransfer++;
            if (IsClosed || payload.Items.Count == 0) return id;
            if (kind == ClipKind.Clipboard)
            {
                foreach (var old in _outgoing.Where(o => o.Offer.Kind == ClipKind.Clipboard))
                {
                    old.Gone = true;
                    if (old.OfferSent) _control.Enqueue(ClipSyncWire.Encode(new ClipMessage.Abandon(old.Offer.Transfer)));
                }
                _outgoing.RemoveAll(o => o.Gone);
            }
            _outgoing.Add(new Outgoing(new ClipOffer(id, kind, x, y, (uint)payload.Items.Count, payload.Total), payload.Items));
        }
        _wake.Release();
        return id;
    }

    /// <summary>Tells the other side what became of its transfer.</summary>
    public void Result(uint transfer, ClipResult status) => Control(new ClipMessage.Result(transfer, status));

    private void Control(ClipMessage message)
    {
        lock (_lock)
        {
            if (IsClosed) return;
            _control.Enqueue(ClipSyncWire.Encode(message));
        }
        _wake.Release();
    }

    /// <summary>The one writer: control messages first, then the next piece of a transfer (clipboard before drops), each write awaited.</summary>
    private async Task<Exception?> WriteAllAsync()
    {
        var gone = new List<Outgoing>();
        try
        {
            await _stream.WriteAsync(ClipSyncWire.Encode(new ClipMessage.Hello(ClipSyncWire.Version)), _closing.Token).ConfigureAwait(false);
            while (!IsClosed)
            {
                byte[]? bytes;
                Outgoing? t = null;
                lock (_lock)
                {
                    if (!_control.TryDequeue(out bytes))
                        t = _outgoing.FirstOrDefault(o => o.Offer.Kind == ClipKind.Clipboard) ?? _outgoing.FirstOrDefault();
                }
                if (bytes is null && t is null)
                {
                    await _wake.WaitAsync(_closing.Token).ConfigureAwait(false);
                    continue;
                }
                if (t is not null)
                {
                    if (!gone.Contains(t)) gone.Add(t);
                    bytes = await NextAsync(t).ConfigureAwait(false);
                    if (bytes is null) continue;
                }
                await _stream.WriteAsync(bytes, _closing.Token).ConfigureAwait(false);
                await _stream.FlushAsync(_closing.Token).ConfigureAwait(false);
                gone.RemoveAll(o => o.Gone && Release(o));
            }
            return null;
        }
        catch (OperationCanceledException) { return null; }
        catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException)
        {
            var wasClosed = IsClosed;
            Close();
            return wasClosed ? null : e;
        }
        finally
        {
            lock (_lock) gone.AddRange(_outgoing);
            foreach (var t in gone) Release(t);
        }
    }

    private static bool Release(Outgoing t)
    {
        t.File?.Dispose();
        t.File = null;
        return true;
    }

    /// <summary>The next message of <paramref name="t"/>, or null when there is none now (it is finished, gone, or was just abandoned).</summary>
    private async Task<byte[]?> NextAsync(Outgoing t)
    {
        var id = t.Offer.Transfer;
        if (!t.OfferSent)
        {
            lock (_lock)
            {
                if (t.Gone) return null;
                t.OfferSent = true;
            }
            return ClipSyncWire.Encode(new ClipMessage.Offer(t.Offer));
        }
        if (t.Gone) { Release(t); return null; }
        if (t.Index >= t.Items.Count)
        {
            lock (_lock)
            {
                if (t.Gone) return null;
                t.Gone = true;
                _outgoing.Remove(t);
            }
            Emit(new ClipEvent.Sent(id));
            return ClipSyncWire.Encode(new ClipMessage.Done(id));
        }
        var item = t.Items[t.Index];
        if (!t.Announced)
        {
            if (item.Format == ClipFormat.File && item.Size > 0)
            {
                try
                {
                    t.File = _options.OpenToSend is { } open
                        ? open(item.Path!)
                        : new FileStream(item.Path!, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.Asynchronous | FileOptions.SequentialScan);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return Abandon(t); }
            }
            t.Announced = true;
            t.SentOfItem = 0;
            return ClipSyncWire.Encode(new ClipMessage.Item(id, (uint)t.Index, new ClipWireItem((byte)item.Format, item.Size, item.Name)));
        }
        var left = item.Size - t.SentOfItem;
        if (left == 0)
        {
            Release(t);
            t.Index++;
            t.Announced = false;
            return null;
        }
        var n = (int)Math.Min(left, ClipSyncWire.MaxChunk);
        ReadOnlyMemory<byte> chunk;
        if (item.Format == ClipFormat.File)
        {
            // Exactly `size` bytes, or the transfer is abandoned: a file that shrank or grew since the offer isn't padded or cut short.
            var buffer = new byte[n];
            try
            {
                var read = await t.File!.ReadAtLeastAsync(buffer, n, throwOnEndOfStream: false, _closing.Token).ConfigureAwait(false);
                if (read != n) return Abandon(t);
                if ((ulong)n == left && t.File.Length != (long)item.Size) return Abandon(t);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return Abandon(t); }
            chunk = buffer;
        }
        else chunk = item.Data.Slice((int)t.SentOfItem, n);
        t.SentOfItem += (ulong)n;
        return ClipSyncWire.Encode(new ClipMessage.Data(id, (uint)t.Index, chunk));
    }

    private byte[]? Abandon(Outgoing t)
    {
        lock (_lock)
        {
            if (t.Gone) return null;
            t.Gone = true;
            _outgoing.Remove(t);
        }
        Release(t);
        Emit(new ClipEvent.Declined(t.Offer.Transfer, ClipDecline.Failed));
        return ClipSyncWire.Encode(new ClipMessage.Abandon(t.Offer.Transfer));
    }

    // MARK: Receiving

    private sealed class Incoming(ClipOffer offer)
    {
        public readonly ClipSyncWire.ItemCheck Check = new(offer);
        public ClipOffer Offer => Check.Offer;
        public string? Folder;
        public readonly List<ReceivedItem> Items = [];
        /// <summary>The item now being received (its number on the wire), its size and how much has come.</summary>
        public uint? Current;
        public ulong Size, Got;
        /// <summary>Bytes of the whole transfer that have come.</summary>
        public ulong Received;
        public ClipFormat? InlineFormat;
        public MemoryStream? Inline;
        public FileStream? File;
        /// <summary>Each folder received (by its wire name's key): where it is here, and the names taken in it.</summary>
        public readonly Dictionary<string, (string Path, HashSet<string> Taken)> Folders = new(StringComparer.Ordinal);
        public readonly HashSet<string> TopTaken = new(StringComparer.Ordinal);
    }

    private readonly System.Collections.Concurrent.ConcurrentQueue<uint> _stops = new();

    /// <summary>
    /// The person here doesn't want a transfer the other side is sending (Stop on a large copy): it is declined (5)
    /// and what came of it thrown away. Nothing happens if it already finished.
    /// </summary>
    public void StopIncoming(uint transfer) => _stops.Enqueue(transfer);

    private async Task HandleAsync(ClipMessage message)
    {
        // Asked from another thread; acted on here, where the transfers are. One still coming always has another message due.
        while (_stops.TryDequeue(out var stopped))
            if (_incoming.TryGetValue(stopped, out var unwanted)) Decline(unwanted, ClipDecline.Failed);
        switch (message)
        {
            case ClipMessage.Offer { Value: var offer }:
                Offered(offer);
                break;
            case ClipMessage.UnknownOffer u:
                // A kind this side can't do: declined, and nothing else changes. Its number counts as seen.
                if (u.Transfer <= _lastOffer) break;
                _lastOffer = u.Transfer;
                Control(new ClipMessage.Decline(u.Transfer, ClipDecline.BadOffer));
                break;
            case ClipMessage.Item i:
                if (!_incoming.TryGetValue(i.Transfer, out var t)) break;
                if ((t.Check.Refusal(i.Value, i.Index) ?? CompleteCurrent(t) ?? Begin(t, i.Value, i.Index)) is { } refused) Decline(t, refused);
                break;
            case ClipMessage.Data d:
                if (!_incoming.TryGetValue(d.Transfer, out var into)) break;
                if (into.Current != d.ItemIndex || (ulong)d.Bytes.Length > into.Size - into.Got) { Decline(into, ClipDecline.BadOffer); break; }
                into.Got += (ulong)d.Bytes.Length;
                into.Received += (ulong)d.Bytes.Length;
                if (into.Inline is { } inline) inline.Write(d.Bytes.Span);
                else if (into.File is { } file)
                {
                    try { await file.WriteAsync(d.Bytes, _closing.Token).ConfigureAwait(false); }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Decline(into, ClipDecline.NoRoom); }
                }
                break;
            case ClipMessage.Done d:
                if (!_incoming.TryGetValue(d.Transfer, out var done)) break;
                if (CompleteCurrent(done) is { } incomplete) { Decline(done, incomplete); break; }
                if (!done.Check.IsComplete) { Decline(done, ClipDecline.BadOffer); break; }
                if (_options.FileReceived is { } received)
                    foreach (var file in done.Items.Where(i => i.Format == ClipFormat.File && i.Path is not null)) received(file.Path!);
                _incoming.Remove(d.Transfer);
                Emit(new ClipEvent.Received(new ReceivedTransfer(d.Transfer, done.Offer.Kind, done.Offer.X, done.Offer.Y, done.Items, done.Folder)));
                break;
            case ClipMessage.Abandon a:
                if (!_incoming.Remove(a.Transfer, out var abandoned)) break;
                Discard(abandoned);
                Emit(new ClipEvent.IncomingEnded(a.Transfer));
                break;
            case ClipMessage.Decline d:
                lock (_lock)
                {
                    foreach (var o in _outgoing.Where(o => o.Offer.Transfer == d.Transfer)) o.Gone = true;
                    _outgoing.RemoveAll(o => o.Gone);
                }
                Emit(new ClipEvent.Declined(d.Transfer, d.Reason));
                break;
            case ClipMessage.Result r:
                Emit(new ClipEvent.Outcome(r.Transfer, r.Status));
                break;
        }
    }

    private void Offered(ClipOffer offer)
    {
        // Numbers only go up: an old or repeated one is ignored.
        if (offer.Transfer <= _lastOffer) return;
        _lastOffer = offer.Transfer;
        if (offer.Kind == ClipKind.Drop && !_options.AcceptDrops)
        {
            Control(new ClipMessage.Decline(offer.Transfer, ClipDecline.BadOffer));
            return;
        }
        if (offer.Kind == ClipKind.Clipboard)
        {
            // A newer copy replaces one still coming.
            foreach (var (id, old) in _incoming.Where(p => p.Value.Offer.Kind == ClipKind.Clipboard).ToList())
            {
                _incoming.Remove(id);
                Discard(old);
                Emit(new ClipEvent.IncomingEnded(id));
            }
        }
        var refusal = _incoming.Count >= ClipSyncWire.MaxOpenTransfers ? ClipDecline.NoRoom : ClipSyncWire.Refusal(offer, Room());
        if (refusal is { } reason)
        {
            Control(new ClipMessage.Decline(offer.Transfer, reason));
            return;
        }
        _incoming[offer.Transfer] = new Incoming(offer);
        Emit(new ClipEvent.Incoming(offer.Transfer, offer.Kind, offer.Total, offer.X, offer.Y));
    }

    /// <summary>Free space less what the transfers already coming may still write.</summary>
    private ulong? Room()
    {
        var free = _options.Room is { } room ? room() : DriveRoom(_options.Staging);
        if (free is not { } bytes) return null;
        var promised = _incoming.Values.Aggregate(0UL, (sum, t) =>
        {
            var left = ClipSyncWire.Footprint(t.Offer) - Math.Min(t.Received, t.Offer.Total);
            return left > ulong.MaxValue - sum ? ulong.MaxValue : sum + left;
        });
        return bytes > promised ? bytes - promised : 0;
    }

    /// <summary>What's free on <paramref name="folder"/>'s drive, leaving 1 GiB for everything else; null when it can't be read.</summary>
    public static ulong? DriveRoom(string folder)
    {
        try
        {
            var free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(folder))!).AvailableFreeSpace;
            return (ulong)Math.Max(free - (1L << 30), 0);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
    }

    /// <summary>Why the item being received isn't whole, or null (also with none).</summary>
    private static ClipDecline? CompleteCurrent(Incoming t)
    {
        if (t.Current is null) return null;
        if (t.Got != t.Size) return ClipDecline.BadOffer;
        t.File?.Dispose();
        t.File = null;
        if (t.Inline is { } inline && t.InlineFormat is { } format) t.Items.Add(new ReceivedItem(format, "", inline.ToArray(), null));
        t.Inline = null;
        t.InlineFormat = null;
        t.Current = null;
        return null;
    }

    /// <summary>Starts taking <paramref name="item"/> (already checked): where its bytes will go. Null, or why it can't be taken.</summary>
    private ClipDecline? Begin(Incoming t, ClipWireItem item, uint index)
    {
        t.Size = item.Size;
        t.Got = 0;
        t.Current = index;
        // Unknown: its bytes are counted and dropped.
        if (item.Known is not { } format) return null;
        if (!format.IsFile())
        {
            // Inline formats are held in memory, so they're held to the clipboard's sizes whatever the kind; the buffer grows with the bytes.
            if (item.Size > (format == ClipFormat.Png ? ClipSyncWire.MaxClipboardImage : ClipSyncWire.MaxClipboardText)) return ClipDecline.TooLarge;
            t.Inline = new MemoryStream();
            t.InlineFormat = format;
            return null;
        }
        try
        {
            if (t.Folder is null)
            {
                var made = Path.Combine(_options.Staging, Guid.NewGuid().ToString("D"));
                Directory.CreateDirectory(made);
                t.Folder = made;
            }
            var name = item.Name!;
            var parentKey = ClipSyncWire.Parent(name) is { } parent ? ClipSyncWire.ItemCheck.Key(parent) : null;
            var (folder, taken) = parentKey is null ? (t.Folder, t.TopTaken) : t.Folders[parentKey];
            var leaf = ClipNames.Unique(_options.LocalPart(name[(name.LastIndexOf('/') + 1)..]), taken);
            var path = Path.Combine(folder, leaf);
            // Whatever the name: nothing is made outside the transfer's folder.
            var root = Path.GetFullPath(t.Folder) + Path.DirectorySeparatorChar;
            if (leaf is "." or ".." || leaf.IndexOfAny([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar]) >= 0
                || !Path.GetFullPath(path).StartsWith(root, StringComparison.Ordinal)) return ClipDecline.BadOffer;
            if (format == ClipFormat.Folder)
            {
                if (Directory.Exists(path) || File.Exists(path)) return ClipDecline.Failed;
                Directory.CreateDirectory(path);
                t.Folders[ClipSyncWire.ItemCheck.Key(name)] = (path, new HashSet<string>(StringComparer.Ordinal));
            }
            else t.File = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 1, FileOptions.Asynchronous);
            t.Items.Add(new ReceivedItem(format, name, null, path));
            return null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or KeyNotFoundException)
        {
            return ClipDecline.Failed;
        }
    }

    private void Decline(Incoming t, ClipDecline reason)
    {
        _incoming.Remove(t.Offer.Transfer);
        Discard(t);
        Control(new ClipMessage.Decline(t.Offer.Transfer, reason));
        Emit(new ClipEvent.IncomingEnded(t.Offer.Transfer));
    }

    private static void Discard(Incoming t)
    {
        t.File?.Dispose();
        t.File = null;
        t.Inline = null;
        if (t.Folder is not { } folder) return;
        try { Directory.Delete(folder, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private void Emit(ClipEvent e)
    {
        try { _onEvent(e); }
        catch (Exception x) when (x is not OutOfMemoryException) { } // a listener's failure never stops the session
    }

    /// <summary>Bytes already read past <c>clipSyncReady</c>, then the stream's own.</summary>
    private sealed class PrefixedStream(ReadOnlyMemory<byte> prefix, Stream inner) : Stream
    {
        private ReadOnlyMemory<byte> _prefix = prefix;

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancel = default)
        {
            if (_prefix.IsEmpty) return inner.ReadAsync(buffer, cancel);
            var n = Math.Min(buffer.Length, _prefix.Length);
            _prefix[..n].CopyTo(buffer);
            _prefix = _prefix[n..];
            return ValueTask.FromResult(n);
        }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancel) => ReadAsync(buffer.AsMemory(offset, count), cancel).AsTask();
        public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
