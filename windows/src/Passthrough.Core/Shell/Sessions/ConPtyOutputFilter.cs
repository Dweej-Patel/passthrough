namespace Passthrough.Core.Shell.Sessions;

/// <summary>
/// Takes out of a pseudoconsole's output what the pseudoconsole itself says to its terminal, which no phone and no
/// recording should see (Spikes/ConPtyProbe/README.md). At start the bundled ConPTY sends <c>ESC[1t ESC[c ESC[?1004h
/// ESC[?9001h</c>: a window report, a device attributes request (left unanswered: nothing stalls), focus reports and
/// win32-input-mode. Those are dropped while they are all that has come; win32-input-mode (<c>?9001</c>) is dropped
/// wherever it appears, since phones send VT keys and nothing may switch them away from that. A program's own focus
/// reports (vim's) pass, once anything else has come first. Not thread-safe.
/// </summary>
public sealed class ConPtyOutputFilter
{
    private static readonly byte[][] Preamble = ["\u001b[1t"u8.ToArray(), "\u001b[c"u8.ToArray(), "\u001b[?1004h"u8.ToArray(), "\u001b[?9001h"u8.ToArray()];
    private static readonly byte[][] Always = ["\u001b[?9001h"u8.ToArray(), "\u001b[?9001l"u8.ToArray()];

    private readonly List<byte> _held = [];
    private bool _inPreamble = true;

    /// <summary>What of <paramref name="data"/> goes on; a sequence cut off at its end is held for the next chunk.</summary>
    public byte[] Filter(ReadOnlySpan<byte> data)
    {
        var input = new byte[_held.Count + data.Length];
        _held.CopyTo(input);
        data.CopyTo(input.AsSpan(_held.Count));
        _held.Clear();
        var output = new List<byte>(input.Length);
        var i = 0;
        while (i < input.Length)
        {
            if (input[i] == 0x1B)
            {
                var rest = input.AsSpan(i);
                var dropped = Match(rest, _inPreamble ? Preamble : Always);
                if (dropped > 0) { i += dropped; continue; }
                if (dropped < 0)
                {
                    // Could still become one: wait for the rest.
                    _held.AddRange(rest.ToArray());
                    break;
                }
            }
            _inPreamble = false;
            output.Add(input[i++]);
        }
        return [.. output];
    }

    /// <summary>What is held back, at the end of the output.</summary>
    public byte[] Flush()
    {
        var rest = _held.ToArray();
        _held.Clear();
        return rest;
    }

    /// <summary>The length of the sequence at the start of <paramref name="rest"/>; -1 when <paramref name="rest"/> is the start of one; 0 when neither.</summary>
    private static int Match(ReadOnlySpan<byte> rest, byte[][] sequences)
    {
        var partial = false;
        foreach (var sequence in sequences)
        {
            if (rest.StartsWith(sequence)) return sequence.Length;
            if (rest.Length < sequence.Length && sequence.AsSpan().StartsWith(rest)) partial = true;
        }
        return partial ? -1 : 0;
    }
}
