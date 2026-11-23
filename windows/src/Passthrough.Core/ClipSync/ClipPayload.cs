using System.Text;

namespace Passthrough.Core.ClipSync;

/// <summary>One thing a side sends: bytes held in memory (text, RTF, HTML, PNG), a file read from <see cref="Path"/> as it goes, or a folder.</summary>
public sealed record ClipItem(ClipFormat Format, string Name, ulong Size, ReadOnlyMemory<byte> Data, string? Path)
{
    public static ClipItem Inline(ClipFormat format, ReadOnlyMemory<byte> data) => new(format, "", (ulong)data.Length, data, null);
    public static ClipItem File(string name, ulong size, string path) => new(ClipFormat.File, name, size, default, path);
    public static ClipItem Folder(string name) => new(ClipFormat.Folder, name, 0, default, null);
}

/// <summary>What one side sends: a clipboard's contents, or files dropped on the view.</summary>
public sealed record ClipPayload(IReadOnlyList<ClipItem> Items)
{
    public ulong Total => Items.Aggregate(0UL, (sum, i) => sum + i.Size);
    public bool HasFiles => Items.Any(i => i.Format.IsFile());
}

/// <summary>One item of a transfer the other side finished sending.</summary>
/// <param name="Name">The name on the wire (a relative path, for files and folders).</param>
/// <param name="Data">Text, RTF, HTML or PNG.</param>
/// <param name="Path">Where a file or folder was put here.</param>
public sealed record ReceivedItem(ClipFormat Format, string Name, byte[]? Data, string? Path);

/// <summary>A transfer the other side finished sending: complete and checked.</summary>
/// <param name="Folder">The folder its files are in (null with none); the receiver decides when it goes.</param>
public sealed record ReceivedTransfer(uint Transfer, ClipKind Kind, ushort X, ushort Y, IReadOnlyList<ReceivedItem> Items, string? Folder)
{
    /// <summary>The files and folders at the top, which hold the rest.</summary>
    public IReadOnlyList<string> TopLevel => [.. Items.Where(i => i.Format.IsFile() && !i.Name.Contains('/') && i.Path is not null).Select(i => i.Path!)];

    public byte[]? Data(ClipFormat format) => Items.FirstOrDefault(i => i.Format == format)?.Data;

    /// <summary>The same contents to send on (a host passing a viewer's copy to its other viewers).</summary>
    public ClipPayload ToPayload()
    {
        var items = new List<ClipItem>();
        foreach (var item in Items)
        {
            if (item.Format == ClipFormat.Folder) items.Add(ClipItem.Folder(item.Name));
            else if (item.Format == ClipFormat.File)
            {
                if (item.Path is null) continue;
                long size;
                try { size = new FileInfo(item.Path).Length; }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { size = 0; }
                items.Add(ClipItem.File(item.Name, (ulong)size, item.Path));
            }
            else if (item.Data is { } data) items.Add(ClipItem.Inline(item.Format, data));
        }
        return new ClipPayload(items);
    }
}

/// <summary>File and folder names as each side can hold them.</summary>
public static class ClipNames
{
    private static readonly HashSet<string> Devices = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "CONIN$", "CONOUT$",
        // Windows takes the superscript digits for these too.
        "COM\u00b9", "COM\u00b2", "COM\u00b3", "LPT\u00b9", "LPT\u00b2", "LPT\u00b3",
    };

    /// <summary>
    /// One part of a name as it goes on the wire: precomposed (NFC), characters the wire refuses replaced, never empty,
    /// <c>.</c> or <c>..</c>, at most 255 UTF-8 bytes (cut before the extension, which stays).
    /// </summary>
    public static string WirePart(string part)
    {
        string normal;
        try { normal = part.Normalize(NormalizationForm.FormC); }
        catch (ArgumentException) { normal = part; } // a lone surrogate: replaced below
        var text = new StringBuilder(normal.Length);
        foreach (var rune in normal.EnumerateRunes())
        {
            var v = rune.Value;
            if (v < 0x20 || v == 0x7F || v is >= 0x80 and <= 0x9F || v is '\\' or ':' or '/' || v == 0xFFFD && !normal.Contains('�')) text.Append('_');
            else text.Append(rune.ToString());
        }
        var clean = text.ToString();
        if (clean.Length == 0 || clean is "." or "..") clean = "_";
        return Shorten(clean, ClipSyncWire.MaxNamePartBytes);
    }

    /// <summary><paramref name="name"/> in at most <paramref name="maxBytes"/> of UTF-8, cut at a character and keeping a short extension.</summary>
    internal static string Shorten(string name, int maxBytes)
    {
        if (Encoding.UTF8.GetByteCount(name) <= maxBytes) return name;
        var dot = name.LastIndexOf('.');
        var ext = dot > 0 && Encoding.UTF8.GetByteCount(name[dot..]) <= 32 ? name[dot..] : "";
        var stem = ext.Length > 0 ? name[..dot] : name;
        var room = maxBytes - Encoding.UTF8.GetByteCount(ext);
        var kept = new StringBuilder();
        var used = 0;
        foreach (var rune in stem.EnumerateRunes())
        {
            if (used + rune.Utf8SequenceLength > room) break;
            used += rune.Utf8SequenceLength;
            kept.Append(rune.ToString());
        }
        if (kept.Length == 0) kept.Append('_');
        return kept + ext;
    }

    /// <summary>The longest part <see cref="WindowsPart"/> gives: under Windows' 255, so a number added to make it unique still fits.</summary>
    public const int MaxWindowsPart = 240;

    /// <summary>
    /// One part of a received name as Windows can hold it: <c>&lt; &gt; " | ? *</c> replaced, no trailing dot or space,
    /// not a device name (CON, NUL, COM1…), at most <see cref="MaxWindowsPart"/> UTF-16 units, and without the
    /// characters that turn the order of a name's letters around on screen (so <c>exe.txt</c> can't be shown for
    /// <c>txt.exe</c>). A receiver renames such parts rather than decline.
    /// </summary>
    public static string WindowsPart(string part)
    {
        var text = new StringBuilder(part.Length);
        foreach (var c in part)
            text.Append(c is '<' or '>' or '"' or '|' or '?' or '*' or '/' or '\\' or ':' || c < 0x20 || c is >= '\u202A' and <= '\u202E' or >= '\u2066' and <= '\u2069' ? '_' : c);
        var clean = text.ToString().TrimEnd('.', ' ');
        if (clean.Length == 0) clean = "_";
        var stem = clean.IndexOf('.') is > 0 and var dot ? clean[..dot] : clean;
        if (Devices.Contains(stem.TrimEnd(' '))) clean = "_" + clean;
        if (clean.Length > MaxWindowsPart)
        {
            var ext = Path.GetExtension(clean);
            if (ext.Length > 32) ext = "";
            clean = clean[..(MaxWindowsPart - ext.Length)].TrimEnd('.', ' ') + ext;
            if (char.IsHighSurrogate(clean[^(ext.Length + 1)])) clean = clean.Remove(clean.Length - ext.Length - 1, 1);
        }
        return clean;
    }

    /// <summary><paramref name="name"/>, or <c>name 2</c>, <c>name 3</c>… so none in <paramref name="taken"/> is the same file ignoring case and normalisation.</summary>
    public static string Unique(string name, HashSet<string> taken)
    {
        var candidate = name;
        for (var n = 2; !taken.Add(ClipSyncWire.ItemCheck.Key(candidate)); n++)
        {
            var ext = Path.GetExtension(name);
            candidate = $"{name[..(name.Length - ext.Length)]} {n}{ext}";
        }
        return candidate;
    }
}

/// <summary>The files and folders a side sends, found on disk.</summary>
public static class ClipFiles
{
    public enum Failure { TooLarge, Unreadable }

    /// <summary>
    /// A symbolic link or a junction: what it points at was not copied, so it is left out. Other reparse points (the
    /// files of a cloud-synced folder, for one) are ordinary files to whoever reads them.
    /// </summary>
    private static bool IsLink(FileSystemInfo info) => info.Attributes.HasFlag(FileAttributes.ReparsePoint) && info.LinkTarget is not null;

    /// <summary>
    /// The files and folders at <paramref name="paths"/> and everything under the folders, named from each one's own
    /// name down, every folder before what's in it. Links and junctions are left out (nothing outside what was copied
    /// is read). Counting stops at the first byte over <paramref name="maxBytes"/> or item over <paramref name="maxItems"/>.
    /// <paramref name="canonical"/> gives each listed thing's real path (every link above it followed, once, now):
    /// what is under it is found from there, so each file's path is where it truly is, and a sender can refuse a file
    /// that isn't there any more when it comes to open it (a folder above it swapped for a link meanwhile).
    /// </summary>
    public static (ClipPayload? Payload, Failure? Failed) Collect(IReadOnlyList<string> paths, ulong? maxBytes = null, int maxItems = int.MaxValue,
        CancellationToken cancel = default, Func<string, string>? canonical = null)
    {
        var items = new List<ClipItem>();
        ulong total = 0;
        var top = new HashSet<string>(StringComparer.Ordinal);

        Failure? Add(FileSystemInfo info, string name)
        {
            if (info is DirectoryInfo) items.Add(ClipItem.Folder(name));
            else
            {
                var size = (ulong)((FileInfo)info).Length;
                total += size;
                if (maxBytes is { } cap && total > cap) return Failure.TooLarge;
                items.Add(ClipItem.File(name, size, info.FullName));
            }
            return items.Count > maxItems ? Failure.TooLarge : null;
        }

        Failure? Walk(DirectoryInfo folder, string name)
        {
            var taken = new HashSet<string>(StringComparer.Ordinal);
            IEnumerable<FileSystemInfo> children;
            try { children = [.. folder.EnumerateFileSystemInfos()]; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; } // an unreadable folder goes empty
            foreach (var child in children.OrderBy(c => c.Name, StringComparer.Ordinal))
            {
                cancel.ThrowIfCancellationRequested();
                if (IsLink(child)) continue;
                var childName = name + "/" + ClipNames.Unique(ClipNames.WirePart(child.Name), taken);
                if (Encoding.UTF8.GetByteCount(childName) > ClipSyncWire.MaxNameBytes) continue; // too deep to name: left out, with what's in it
                if (Add(child, childName) is { } failed) return failed;
                if (child is DirectoryInfo sub && Walk(sub, childName) is { } inside) return inside;
            }
            return null;
        }

        foreach (var path in paths)
        {
            FileSystemInfo info;
            try
            {
                info = Directory.Exists(path) ? new DirectoryInfo(path) : new FileInfo(path);
                if (!info.Exists) return (null, Failure.Unreadable);
                if (IsLink(info)) continue;
                var name = ClipNames.Unique(ClipNames.WirePart(info.Name.Length > 0 ? info.Name : "Drive"), top);
                if (canonical is not null)
                {
                    var real = canonical(path);
                    info = info is DirectoryInfo ? new DirectoryInfo(real) : new FileInfo(real);
                }
                if (Add(info, name) is { } failed) return (null, failed);
                if (info is DirectoryInfo folder && Walk(folder, name) is { } inside) return (null, inside);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return (null, Failure.Unreadable); }
        }
        return (new ClipPayload(items), null);
    }
}
