using System.Buffers.Binary;
using System.Text;

namespace Passthrough.Core.ClipSync;

public enum ClipKind : byte { Clipboard = 0, Drop = 1 }

public enum ClipFormat : byte
{
    Text = 1, Rtf = 2, Html = 3, Png = 4,
    File = 16, Folder = 17,
}

public enum ClipDecline : byte { TooLarge = 1, NoRoom = 2, SyncOff = 3, BadOffer = 4, Failed = 5 }

public enum ClipResult : byte { Placed = 0, SavedToDownloads = 1, Failed = 2 }

/// <summary>A transfer's header: its items follow, each as <c>item</c> just before its <c>data</c>.</summary>
public readonly record struct ClipOffer(uint Transfer, ClipKind Kind, ushort X, ushort Y, uint Count, ulong Total);

/// <summary>One item as announced. <see cref="Format"/> is the wire's byte: one this side doesn't know has its bytes skipped.</summary>
public readonly record struct ClipWireItem(byte Format, ulong Size, string? Name)
{
    public ClipFormat? Known => Enum.IsDefined((ClipFormat)Format) ? (ClipFormat)Format : null;
}

public abstract record ClipMessage
{
    public sealed record Hello(byte Version) : ClipMessage;
    public sealed record Offer(ClipOffer Value) : ClipMessage;
    /// <summary>An offer of a kind this side doesn't know: declined (4), nothing else changes.</summary>
    public sealed record UnknownOffer(uint Transfer) : ClipMessage;
    /// <summary>Item <paramref name="Index"/> (from 0) of a transfer. A name that isn't UTF-8 arrives as null (no check passes it).</summary>
    public sealed record Item(uint Transfer, uint Index, ClipWireItem Value) : ClipMessage;
    public sealed record Data(uint Transfer, uint ItemIndex, ReadOnlyMemory<byte> Bytes) : ClipMessage;
    public sealed record Done(uint Transfer) : ClipMessage;
    public sealed record Abandon(uint Transfer) : ClipMessage;
    public sealed record Decline(uint Transfer, ClipDecline Reason) : ClipMessage;
    public sealed record Result(uint Transfer, ClipResult Status) : ClipMessage;
    /// <summary>A type this side doesn't know, or a payload too short to read: skipped.</summary>
    public sealed record Unknown(byte Type) : ClipMessage;
}

/// <summary>A payload longer than <see cref="ClipSyncWire.MaxPayload"/>: the connection is closed.</summary>
public sealed class ClipPayloadTooLargeException() : IOException("A clipboard sync message was too long.");

/// <summary>
/// Clipboard sync between computers (protocol/README.md, "Clipboard sync"; a port of ClipSyncWire.swift): after
/// <c>clipSyncReady</c> the connection carries messages of one type byte, a 4-byte big-endian payload length and the
/// payload, both ways, the same in each direction. A copy or a drop is a transfer: an <c>offer</c>, then for each item
/// an <c>item</c> and its bytes as <c>data</c>, then <c>done</c>.
/// </summary>
public static class ClipSyncWire
{
    public const byte Version = 1;
    /// <summary>Largest payload either side takes; a larger one ends the connection.</summary>
    public const int MaxPayload = (1 << 20) + 64;
    /// <summary>Most bytes a sender puts in one <c>data</c> message.</summary>
    public const int MaxChunk = 256 << 10;
    /// <summary>Most items in a clipboard transfer.</summary>
    public const int MaxItems = 10_000;
    /// <summary>Most items in a drop this side takes.</summary>
    public const uint MaxDropItems = 50_000;
    /// <summary>What each item of a drop counts against free space on top of its size (a folder or an empty file still takes room).</summary>
    public const ulong DropItemOverhead = 4096;
    /// <summary>
    /// A copy of files larger than this (50 MB, counted in millions of bytes as sizes are shown) isn't sent until the
    /// person says so; a copy that large coming in can be stopped.
    /// </summary>
    public const ulong AskAbove = 50_000_000;
    public const int MaxNameBytes = 1024;
    public const int MaxNamePartBytes = 255;
    /// <summary>Clipboard transfers only: text, RTF and HTML each; PNG; files and folders in all.</summary>
    public const ulong MaxClipboardText = 16 << 20;
    public const ulong MaxClipboardImage = 64 << 20;
    public const ulong MaxClipboardFiles = 500_000_000;
    /// <summary>Transfers a receiver takes at once: one more is declined (2).</summary>
    public const int MaxOpenTransfers = 4;
    public const int HeaderLength = 5;

    private const byte THello = 1, TOffer = 2, TData = 3, TDone = 4, TAbandon = 5, TDecline = 6, TResult = 7, TItem = 8;

    public static bool IsFile(this ClipFormat format) => format is ClipFormat.File or ClipFormat.Folder;

    // MARK: Encoding

    public static byte[] Encode(ClipMessage message)
    {
        switch (message)
        {
            case ClipMessage.Hello h:
                return Frame(THello, 2, p => { p[0] = h.Version; p[1] = 0; });
            case ClipMessage.Offer { Value: var o }:
                return Frame(TOffer, 21, p =>
                {
                    BinaryPrimitives.WriteUInt32BigEndian(p, o.Transfer);
                    p[4] = (byte)o.Kind;
                    BinaryPrimitives.WriteUInt16BigEndian(p[5..], o.X);
                    BinaryPrimitives.WriteUInt16BigEndian(p[7..], o.Y);
                    BinaryPrimitives.WriteUInt32BigEndian(p[9..], o.Count);
                    BinaryPrimitives.WriteUInt64BigEndian(p[13..], o.Total);
                });
            case ClipMessage.Item i:
                var name = Encoding.UTF8.GetBytes(i.Value.Name ?? "");
                if (name.Length > ushort.MaxValue) throw new ArgumentException("An item's name is at most 65,535 bytes.");
                return Frame(TItem, 19 + name.Length, p =>
                {
                    BinaryPrimitives.WriteUInt32BigEndian(p, i.Transfer);
                    BinaryPrimitives.WriteUInt32BigEndian(p[4..], i.Index);
                    p[8] = i.Value.Format;
                    BinaryPrimitives.WriteUInt64BigEndian(p[9..], i.Value.Size);
                    BinaryPrimitives.WriteUInt16BigEndian(p[17..], (ushort)name.Length);
                    name.CopyTo(p[19..]);
                });
            case ClipMessage.Data d:
                return Frame(TData, 8 + d.Bytes.Length, p =>
                {
                    BinaryPrimitives.WriteUInt32BigEndian(p, d.Transfer);
                    BinaryPrimitives.WriteUInt32BigEndian(p[4..], d.ItemIndex);
                    d.Bytes.Span.CopyTo(p[8..]);
                });
            case ClipMessage.Done d: return Frame(TDone, 4, p => BinaryPrimitives.WriteUInt32BigEndian(p, d.Transfer));
            case ClipMessage.Abandon a: return Frame(TAbandon, 4, p => BinaryPrimitives.WriteUInt32BigEndian(p, a.Transfer));
            case ClipMessage.Decline d:
                return Frame(TDecline, 5, p => { BinaryPrimitives.WriteUInt32BigEndian(p, d.Transfer); p[4] = (byte)d.Reason; });
            case ClipMessage.Result r:
                return Frame(TResult, 5, p => { BinaryPrimitives.WriteUInt32BigEndian(p, r.Transfer); p[4] = (byte)r.Status; });
            default:
                throw new ArgumentException("Not a message this side sends.");
        }
    }

    private delegate void Fill(Span<byte> payload);

    private static byte[] Frame(byte type, int length, Fill fill)
    {
        if (length > MaxPayload) throw new ArgumentException("A clipboard sync payload is at most 1 MiB + 64 bytes.");
        var bytes = new byte[HeaderLength + length];
        bytes[0] = type;
        BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(1), (uint)length);
        fill(bytes.AsSpan(HeaderLength));
        return bytes;
    }

    // MARK: Decoding

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>One message from its type and payload. Extra bytes after a known layout are ignored; too few make it <see cref="ClipMessage.Unknown"/>.</summary>
    public static ClipMessage Decode(byte type, ReadOnlyMemory<byte> payload)
    {
        var p = payload.Span;
        switch (type)
        {
            case THello when p.Length >= 1:
                return new ClipMessage.Hello(p[0]);
            case TOffer when p.Length >= 21:
                var transfer = BinaryPrimitives.ReadUInt32BigEndian(p);
                if (p[4] > (byte)ClipKind.Drop) return new ClipMessage.UnknownOffer(transfer);
                return new ClipMessage.Offer(new ClipOffer(transfer, (ClipKind)p[4], BinaryPrimitives.ReadUInt16BigEndian(p[5..]),
                    BinaryPrimitives.ReadUInt16BigEndian(p[7..]), BinaryPrimitives.ReadUInt32BigEndian(p[9..]), BinaryPrimitives.ReadUInt64BigEndian(p[13..])));
            case TItem when p.Length >= 19 && p.Length >= 19 + BinaryPrimitives.ReadUInt16BigEndian(p[17..]):
                string? name;
                try { name = StrictUtf8.GetString(p.Slice(19, BinaryPrimitives.ReadUInt16BigEndian(p[17..]))); }
                catch (DecoderFallbackException) { name = null; }
                return new ClipMessage.Item(BinaryPrimitives.ReadUInt32BigEndian(p), BinaryPrimitives.ReadUInt32BigEndian(p[4..]),
                    new ClipWireItem(p[8], BinaryPrimitives.ReadUInt64BigEndian(p[9..]), name));
            case TData when p.Length >= 8:
                return new ClipMessage.Data(BinaryPrimitives.ReadUInt32BigEndian(p), BinaryPrimitives.ReadUInt32BigEndian(p[4..]), payload[8..]);
            case TDone when p.Length >= 4: return new ClipMessage.Done(BinaryPrimitives.ReadUInt32BigEndian(p));
            case TAbandon when p.Length >= 4: return new ClipMessage.Abandon(BinaryPrimitives.ReadUInt32BigEndian(p));
            case TDecline when p.Length >= 5:
                return new ClipMessage.Decline(BinaryPrimitives.ReadUInt32BigEndian(p), p[4] is >= 1 and <= 5 ? (ClipDecline)p[4] : ClipDecline.Failed);
            case TResult when p.Length >= 5:
                return new ClipMessage.Result(BinaryPrimitives.ReadUInt32BigEndian(p), p[4] <= 2 ? (ClipResult)p[4] : ClipResult.Failed);
            default:
                return new ClipMessage.Unknown(type);
        }
    }

    /// <summary>Reads messages off a stream, one at a time.</summary>
    public sealed class Reader(Stream stream)
    {
        private readonly byte[] _header = new byte[HeaderLength];

        /// <summary>The next message, or null at the end of the stream.</summary>
        public async Task<ClipMessage?> ReadAsync(CancellationToken cancel = default)
        {
            if (!await FillAsync(_header, cancel).ConfigureAwait(false)) return null;
            var length = BinaryPrimitives.ReadUInt32BigEndian(_header.AsSpan(1));
            if (length > MaxPayload) throw new ClipPayloadTooLargeException();
            var payload = new byte[length];
            if (length > 0 && !await FillAsync(payload, cancel).ConfigureAwait(false)) throw new EndOfStreamException("The stream closed mid-message.");
            return Decode(_header[0], payload);
        }

        private async Task<bool> FillAsync(byte[] buffer, CancellationToken cancel)
        {
            var read = 0;
            while (read < buffer.Length)
            {
                var n = await stream.ReadAsync(buffer.AsMemory(read), cancel).ConfigureAwait(false);
                if (n == 0)
                {
                    if (read == 0) return false;
                    throw new EndOfStreamException("The stream closed mid-message.");
                }
                read += n;
            }
            return true;
        }
    }

    // MARK: Checks

    /// <summary>
    /// Whether <paramref name="name"/> is a relative path this side will make: parts separated by the <c>/</c> code
    /// point, none empty, <c>.</c> or <c>..</c>, none with NUL, <c>\</c>, <c>:</c> or control characters, each at most
    /// 255 UTF-8 bytes and all at most 1024. Checked over code points, never grapheme clusters.
    /// </summary>
    public static bool IsValidName(string? name)
    {
        if (string.IsNullOrEmpty(name) || Encoding.UTF8.GetByteCount(name) > MaxNameBytes) return false;
        foreach (var part in name.Split('/'))
        {
            if (part.Length == 0 || part is "." or ".." || Encoding.UTF8.GetByteCount(part) > MaxNamePartBytes) return false;
            foreach (var rune in part.EnumerateRunes())
            {
                var v = rune.Value;
                if (v < 0x20 || v == 0x7F || v is >= 0x80 and <= 0x9F || v == '\\' || v == ':') return false;
                // A lone surrogate isn't a code point: EnumerateRunes gives U+FFFD for it, which UTF-8 from the wire never holds unasked.
            }
        }
        return true;
    }

    /// <summary>The folder a name is in, or null at the top.</summary>
    public static string? Parent(string name) => name.LastIndexOf('/') is >= 0 and var slash ? name[..slash] : null;

    /// <summary>What a transfer may take of the disk: its bytes, and for a drop something for each item too.</summary>
    public static ulong Footprint(ClipOffer offer)
    {
        var overhead = offer.Kind == ClipKind.Drop ? offer.Count * DropItemOverhead : 0;
        return offer.Total > ulong.MaxValue - overhead ? ulong.MaxValue : offer.Total + overhead;
    }

    /// <summary>
    /// Why a transfer's header can't be taken, or null. <paramref name="room"/>: bytes free where files go; unknown
    /// (null), a drop is refused, since it has no limit of its own.
    /// </summary>
    public static ClipDecline? Refusal(ClipOffer offer, ulong? room, uint maxDropItems = MaxDropItems)
    {
        var cap = offer.Kind == ClipKind.Clipboard ? MaxItems : maxDropItems;
        if (offer.Count == 0) return ClipDecline.BadOffer;
        if (offer.Count > cap) return ClipDecline.TooLarge;
        if (offer.Kind == ClipKind.Clipboard && offer.Total > MaxClipboardFiles + 2 * MaxClipboardText + MaxClipboardImage) return ClipDecline.TooLarge;
        if (room is { } free ? Footprint(offer) > free : offer.Kind == ClipKind.Drop) return ClipDecline.NoRoom;
        return null;
    }

    /// <summary>
    /// Checks a transfer's items as they come, and at <c>done</c> that they were all there: in order, sizes within the
    /// total, files only or none, each name once (ignoring case and normalisation, as Windows' file systems see them),
    /// every folder before what's in it, within the clipboard's limits.
    /// </summary>
    public sealed class ItemCheck(ClipOffer offer)
    {
        private readonly HashSet<byte> _formats = [];
        private readonly HashSet<string> _names = new(StringComparer.Ordinal);
        private readonly HashSet<string> _folders = new(StringComparer.Ordinal);
        private bool _hasFiles, _hasOther;

        public ClipOffer Offer { get; } = offer;
        public uint Next { get; private set; }
        public ulong Sum { get; private set; }

        /// <summary>What two names that are the same file here have in common.</summary>
        public static string Key(string name) => name.Normalize(NormalizationForm.FormC).ToUpperInvariant();

        /// <summary>Why <paramref name="item"/>, announced as <paramref name="index"/>, can't be taken, or null.</summary>
        public ClipDecline? Refusal(ClipWireItem item, uint index)
        {
            if (index != Next || index >= Offer.Count) return ClipDecline.BadOffer;
            if (item.Size > Offer.Total - Sum) return ClipDecline.BadOffer;
            var total = Sum + item.Size;
            if (item.Known is { } format)
            {
                if (format.IsFile())
                {
                    if (_hasOther || !IsValidName(item.Name)) return ClipDecline.BadOffer;
                    string key;
                    try { key = Key(item.Name!); }
                    catch (ArgumentException) { return ClipDecline.BadOffer; } // not Unicode
                    if (Parent(key) is { } parent && !_folders.Contains(parent)) return ClipDecline.BadOffer;
                    if (_names.Contains(key)) return ClipDecline.BadOffer;
                    if (format == ClipFormat.Folder)
                    {
                        if (item.Size != 0) return ClipDecline.BadOffer;
                        _folders.Add(key);
                    }
                    _names.Add(key);
                    _hasFiles = true;
                }
                else
                {
                    if (_hasFiles || !string.IsNullOrEmpty(item.Name) || !_formats.Add(item.Format)) return ClipDecline.BadOffer;
                    _hasOther = true;
                }
                if (Offer.Kind == ClipKind.Clipboard)
                {
                    var over = format switch
                    {
                        ClipFormat.Text or ClipFormat.Rtf or ClipFormat.Html => item.Size > MaxClipboardText,
                        ClipFormat.Png => item.Size > MaxClipboardImage,
                        _ => total > MaxClipboardFiles,
                    };
                    if (over) return ClipDecline.TooLarge;
                }
            }
            Next++;
            Sum = total;
            return null;
        }

        /// <summary>At <c>done</c>: every item announced, and the sizes exactly the total.</summary>
        public bool IsComplete => Next == Offer.Count && Sum == Offer.Total;
    }
}
