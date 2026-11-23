namespace Passthrough.Core.Shell.Sessions;

/// <summary>
/// The last <see cref="Capacity"/> bytes written to it: what a phone attaching late is replayed so its terminal shows
/// where the session is (a port of ScrollbackBuffer.swift). Not thread-safe; the session manager guards it.
/// </summary>
internal sealed class ScrollbackBuffer(int capacity)
{
    /// <summary>How far into the contents a replay looks for a line start.</summary>
    internal const int ResyncWindow = 4096;

    public int Capacity { get; } = Math.Max(0, capacity);

    /// <summary>Up to twice <see cref="Capacity"/>, so trimming (a copy) happens once per capacity appended.</summary>
    private byte[] _bytes = [];
    private int _length;
    /// <summary>Older output has been dropped, so the contents may begin mid-stream.</summary>
    private bool _trimmed;
    /// <summary>The terminal modes in force at <c>_bytes[_baseIndex]</c>, as what came before left them.</summary>
    private TerminalModes _base = new();
    private int _baseIndex;

    /// <summary>The terminal modes in force after everything appended.</summary>
    public TerminalModes Modes { get; } = new();

    public void Append(ReadOnlySpan<byte> data)
    {
        EnsureRoom(data.Length);
        data.CopyTo(_bytes.AsSpan(_length));
        _length += data.Length;
        Modes.Scan(data);
        var start = Math.Max(0, _length - Capacity); // where the contents begin
        if (start > _baseIndex)
        {
            _base.Scan(_bytes.AsSpan(_baseIndex, start - _baseIndex));
            _baseIndex = start;
        }
        if (_length > 2 * Capacity)
        {
            // Re-based at index 0, which is where the contents begin.
            var keep = Math.Min(Capacity, _length);
            Buffer.BlockCopy(_bytes, _length - keep, _bytes, 0, keep);
            _length = keep;
            _baseIndex = 0;
            _trimmed = true;
        }
    }

    private void EnsureRoom(int more)
    {
        if (_length + more <= _bytes.Length) return;
        Array.Resize(ref _bytes, Math.Max(_length + more, Math.Max(256, _bytes.Length * 2)));
    }

    private int ContentsStart => _length > Capacity ? _length - Capacity : 0;

    /// <summary>The last <see cref="Capacity"/> bytes.</summary>
    public ReadOnlySpan<byte> Contents => _bytes.AsSpan(ContentsStart, _length - ContentsStart);

    /// <summary>The replay begins after the session's start: what came first is gone.</summary>
    public bool IsPartial => _trimmed || _length > Capacity;

    /// <summary>
    /// What a late attach is replayed: the contents, but once older output was cut off, from just after the first
    /// newline near their start (else from the first whole UTF-8 character), so the replay does not begin inside a
    /// character or an escape sequence. A partial replay begins by turning on the modes the cut-off output had turned on.
    /// </summary>
    public byte[] Replay()
    {
        var start = ContentsStart;
        if (!IsPartial) return _bytes.AsSpan(start, _length - start).ToArray();
        var window = Math.Min(ResyncWindow, _length - start);
        var newline = _bytes.AsSpan(start, window).IndexOf((byte)0x0A);
        var from = start;
        if (newline >= 0) from = start + newline + 1;
        else while (from < _length && (_bytes[from] & 0xC0) == 0x80) from++;
        var restoring = _base.Scanned(_bytes.AsSpan(_baseIndex, from - _baseIndex)).Restoring();
        var tail = _bytes.AsSpan(from, _length - from);
        var result = new byte[restoring.Length + tail.Length];
        restoring.CopyTo(result, 0);
        tail.CopyTo(result.AsSpan(restoring.Length));
        return result;
    }
}
