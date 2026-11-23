using System.Globalization;

namespace Passthrough.Core.Shell;

/// <summary>
/// One step of a recorded session's replay: output, or the terminal taking a new size. A replay starts with the size
/// the terminal had when its first output was written, so it is fed at the width the shell drew for.
/// </summary>
public abstract record ShellReplayChunk
{
    private ShellReplayChunk() { }

    public sealed record Output(byte[] Data) : ShellReplayChunk
    {
        public bool Equals(Output? other) => other is not null && Data.AsSpan().SequenceEqual(other.Data);
        public override int GetHashCode() => Data.Length;
        public override string ToString() => $"Output({System.Text.Encoding.UTF8.GetString(Data)})";
    }

    public sealed record Resize(int Cols, int Rows) : ShellReplayChunk;
}

/// <summary>Building, sending and receiving replays (protocol/README.md, <c>transcriptData</c>). A port of ShellReplay.swift.</summary>
public static class ShellReplay
{
    /// <summary>A size outside 1…this in either direction is not one a terminal had: ignored.</summary>
    public const int MaxDimension = 1000;

    public static bool IsValid(int cols, int rows) => cols is >= 1 and <= MaxDimension && rows is >= 1 and <= MaxDimension;

    /// <summary>A recorded dimension brought into 1…<see cref="MaxDimension"/>.</summary>
    public static int Clamp(int value) => Math.Clamp(value, 1, MaxDimension);

    /// <summary>The payload of an asciicast v2 resize event, "COLSxROWS".</summary>
    public static string SizeString(int cols, int rows) => string.Create(CultureInfo.InvariantCulture, $"{cols}x{rows}");

    /// <summary>Parses "COLSxROWS"; null for anything else or an invalid size.</summary>
    public static (int Cols, int Rows)? ParseSize(string text)
    {
        var parts = text.Split('x');
        if (parts.Length != 2) return null;
        // Int(…) in Swift takes an optional sign; an invalid size is refused below either way.
        if (!int.TryParse(parts[0], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var cols)
            || !int.TryParse(parts[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var rows)
            || !IsValid(cols, rows)) return null;
        return (cols, rows);
    }

    /// <summary>The most columns and the most rows the replay's sizes ask for; null when it has no size.</summary>
    public static (int Cols, int Rows)? LargestGrid(IEnumerable<ShellReplayChunk> chunks)
    {
        int cols = 0, rows = 0;
        foreach (var chunk in chunks)
            if (chunk is ShellReplayChunk.Resize r) { cols = Math.Max(cols, r.Cols); rows = Math.Max(rows, r.Rows); }
        return cols > 0 && rows > 0 ? (cols, rows) : null;
    }

    /// <summary>How much a font must shrink (never grow) for a grid needing <c>needed</c> points to fit <c>available</c>, but not below <paramref name="minimum"/>.</summary>
    public static double FitScale(double neededWidth, double neededHeight, double availableWidth, double availableHeight, double minimum)
    {
        if (neededWidth <= 0 || neededHeight <= 0 || availableWidth <= 0 || availableHeight <= 0) return 1;
        var scale = Math.Min(1, Math.Min(availableWidth / neededWidth, availableHeight / neededHeight));
        return Math.Max(Math.Min(minimum, 1), scale);
    }

    /// <summary>
    /// The <c>transcriptData</c> lines for a replay: output joined into pieces of at most <paramref name="chunkSize"/>
    /// bytes, a size change as <c>cols</c>/<c>rows</c> on the line whose data follows it (a line with empty data when no
    /// output follows), and <c>done: true</c> on the last line. An empty replay is one empty <c>done</c> line.
    /// </summary>
    public static List<ShellEnvelope> TranscriptLines(string session, IEnumerable<ShellReplayChunk> chunks, int chunkSize = RemoteShell.OutputChunk)
    {
        var lines = new List<ShellEnvelope>();
        (int Cols, int Rows)? size = null;
        var pending = new List<byte>();
        chunkSize = Math.Max(1, chunkSize);

        void Line(ReadOnlySpan<byte> data)
        {
            var piece = new ShellEnvelope(ShellEnvelope.TranscriptData) { Session = session, Data = Convert.ToBase64String(data) };
            if (size is { } s) { piece.Cols = s.Cols; piece.Rows = s.Rows; }
            size = null;
            lines.Add(piece);
        }
        // Sends full pieces (all of pending when all), keeping small output to join the next.
        void Drain(bool all)
        {
            var offset = 0;
            var bytes = pending.ToArray();
            while (bytes.Length - offset >= chunkSize || (all && offset < bytes.Length))
            {
                var end = Math.Min(offset + chunkSize, bytes.Length);
                Line(bytes.AsSpan(offset, end - offset));
                offset = end;
            }
            pending.RemoveRange(0, offset);
        }
        foreach (var chunk in chunks)
        {
            switch (chunk)
            {
                case ShellReplayChunk.Resize r:
                    Drain(all: true);
                    size = (r.Cols, r.Rows); // consecutive sizes: the last one wins
                    break;
                case ShellReplayChunk.Output o:
                    pending.AddRange(o.Data);
                    Drain(all: false);
                    break;
            }
        }
        Drain(all: true);
        if (size is not null || lines.Count == 0) Line([]);
        lines[^1].Done = true;
        return lines;
    }

    /// <summary>The phone's side: a replay rebuilt from <c>transcriptData</c> lines, in order.</summary>
    public sealed class Collector
    {
        private readonly List<ShellReplayChunk> _done = [];
        private readonly List<byte> _pending = [];

        /// <summary>The replay so far: consecutive output joined.</summary>
        public List<ShellReplayChunk> Chunks => _pending.Count == 0 ? [.. _done] : [.. _done, new ShellReplayChunk.Output([.. _pending])];

        /// <summary>One line's contents: its size change (if any, and valid) comes before its data.</summary>
        public void Add(ReadOnlySpan<byte> data, int? cols = null, int? rows = null)
        {
            if (cols is { } c && rows is { } r && IsValid(c, r))
            {
                if (_pending.Count > 0) { _done.Add(new ShellReplayChunk.Output([.. _pending])); _pending.Clear(); }
                _done.Add(new ShellReplayChunk.Resize(c, r));
            }
            _pending.AddRange(data);
        }
    }
}
