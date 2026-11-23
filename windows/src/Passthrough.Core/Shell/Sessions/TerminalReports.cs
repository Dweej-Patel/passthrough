namespace Passthrough.Core.Shell.Sessions;

/// <summary>
/// What a terminal sends a shell by itself, not because anyone pressed a key: its answers to a program's questions
/// (where the cursor is, what it is, its colours and size, which modes are on), and focus in and out (a port of
/// TerminalReports.swift). A session shown in two terminals at once gets these from both; only the terminal the session
/// follows should answer, and none of them is a sign that someone took over the keyboard.
/// </summary>
internal static class TerminalReports
{
    private static readonly byte[] StatusQuery = "\u001b]7501;?"u8.ToArray();

    /// <summary><paramref name="data"/> without the reports in it, whole ones only: anything cut off or not known is left, as typing.</summary>
    public static byte[] Removing(ReadOnlySpan<byte> data)
    {
        if (data.IndexOf((byte)0x1B) < 0) return data.ToArray(); // typing, as nearly all of it is
        var kept = new List<byte>(data.Length);
        var i = 0;
        while (i < data.Length)
        {
            if (data[i] == 0x1B && Report(data, i) is { } end) i = end;
            else kept.Add(data[i++]);
        }
        return [.. kept];
    }

    /// <summary>
    /// <paramref name="data"/> without a terminal's answers to OSC 7501's question: the host answers that itself for
    /// every terminal a session is shown in, so a second answer would reach the program as typing.
    /// </summary>
    public static byte[] RemovingProgramStatusReplies(ReadOnlySpan<byte> data)
    {
        if (data.IndexOf((byte)0x1B) < 0) return data.ToArray();
        var kept = new List<byte>(data.Length);
        var i = 0;
        while (i < data.Length)
        {
            if (data[i] == 0x1B && data[i..].StartsWith(StatusQuery) && StringEnd(data, i + 2) is { } end) i = end;
            else kept.Add(data[i++]);
        }
        return [.. kept];
    }

    private static int? Report(ReadOnlySpan<byte> b, int start)
    {
        if (start + 1 >= b.Length) return null;
        return b[start + 1] switch
        {
            (byte)'[' => ControlSequence(b, start),
            // OSC (colours, the title, the clipboard), DCS (settings, the version) and APC (images): a key never sends one.
            (byte)']' or (byte)'P' or (byte)'_' => StringEnd(b, start + 2),
            _ => null,
        };
    }

    /// <summary><c>ESC [ params intermediates final</c>, when it is one a terminal reports with.</summary>
    private static int? ControlSequence(ReadOnlySpan<byte> b, int start)
    {
        var i = start + 2;
        var paramsStart = i;
        while (i < b.Length && b[i] is >= 0x30 and <= 0x3F) i++;
        var parameters = b[paramsStart..i];
        var interStart = i;
        while (i < b.Length && b[i] is >= 0x20 and <= 0x2F) i++;
        var intermediates = b[interStart..i];
        if (i >= b.Length || b[i] is < 0x40 or > 0x7E) return null;
        var final = b[i];
        int? first = parameters.Length > 0 ? parameters[0] : null;
        var isReport = (char)final switch
        {
            // The cursor's place: row ; column.
            'R' => intermediates.IsEmpty && parameters.IndexOf((byte)';') >= 0,
            // What the terminal is (primary, secondary, tertiary attributes).
            'c' => intermediates.IsEmpty && first is '?' or '>' or '=',
            // Status: 0 n, 3 n, or a private ? … n.
            'n' => intermediates.IsEmpty && (parameters.SequenceEqual("0"u8) || parameters.SequenceEqual("3"u8) || first == '?'),
            // Whether a mode is set (… $ y).
            'y' => intermediates.SequenceEqual("$"u8),
            // The keyboard protocol in use (? flags u).
            'u' => intermediates.IsEmpty && first == '?',
            // The window's size, place or state.
            't' => intermediates.IsEmpty && !parameters.IsEmpty,
            // Focus in and out.
            'I' or 'O' => parameters.IsEmpty && intermediates.IsEmpty,
            _ => false,
        };
        return isReport ? i + 1 : null;
    }

    /// <summary>Past the BEL or <c>ESC \</c> that ends a string sequence; null when it isn't ended yet.</summary>
    private static int? StringEnd(ReadOnlySpan<byte> b, int start)
    {
        for (var i = start; i < b.Length; i++)
        {
            if (b[i] == 0x07) return i + 1;
            if (b[i] == 0x1B) return i + 1 < b.Length && b[i + 1] == (byte)'\\' ? i + 2 : null;
        }
        return null;
    }
}
