using System.Text;

namespace Passthrough.Core.Shell.Sessions;

/// <summary>
/// Whether a shell that has gone quiet is waiting on a person: a question near the bottom of its output ("Do you want
/// to make this edit?", "Continue? [y/N]", a password prompt). A heuristic over the screen's last lines, never over
/// anything typed; null means nothing looked like one. A port of ShellQuestion.swift.
/// </summary>
internal static class ShellQuestion
{
    /// <summary>How far up from the bottom a question may sit (menus of choices often follow it).</summary>
    internal const int LinesLooked = 12;
    internal const int MaxLength = 120;
    private const string Trimmed = " \t│┃║╭╮╰╯─━═┌┐└┘|❯›>•·*";

    public static string? Find(ReadOnlySpan<byte> tail)
    {
        var lines = VisibleLines(Encoding.UTF8.GetString(tail));
        foreach (var line in lines.Skip(Math.Max(0, lines.Count - LinesLooked)).Reverse())
            if (LooksAsked(line))
            {
                var chars = new StringInfoText(line);
                return chars.Length > MaxLength ? chars.Prefix(MaxLength - 1) + "…" : line;
            }
        return null;
    }

    private static bool LooksAsked(string line)
    {
        var lower = line.ToLowerInvariant();
        foreach (var choice in new[] { "[y/n]", "(y/n)", "[yes/no]", "(yes/no)" })
            if (lower.Contains(choice, StringComparison.Ordinal)) return true;
        if (lower.EndsWith("password:", StringComparison.Ordinal) || lower.EndsWith("passphrase:", StringComparison.Ordinal)
            || lower.Contains("password for ", StringComparison.Ordinal)) return true;
        // A sentence ending in a question mark, not a lone "?" or a path with one.
        if (!line.EndsWith('?')) return false;
        return line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length >= 2 && new StringInfoText(line).Length >= 8;
    }

    /// <summary>
    /// The text a terminal would show, one line per row: escape sequences dropped, cursor moves and carriage returns
    /// taken as line breaks, box drawing and selection markers trimmed.
    /// </summary>
    internal static List<string> VisibleLines(string text)
    {
        var o = new StringBuilder();
        var runes = text.EnumerateRunes().GetEnumerator();
        while (runes.MoveNext())
        {
            var c = runes.Current.Value;
            if (c == 0x1B)
            {
                if (!runes.MoveNext()) break;
                var next = runes.Current.Value;
                if (next == '[')
                {
                    // CSI: parameters, then a final byte in @...~.
                    while (runes.MoveNext())
                    {
                        var p = runes.Current.Value;
                        if (p is >= 0x40 and <= 0x7E)
                        {
                            // Moves to another row or clears: a new line as far as reading goes.
                            if ("HfABEFdJ".Contains((char)p)) o.Append('\n');
                            break;
                        }
                    }
                }
                else if (next == ']')
                {
                    // OSC (titles, links): up to BEL or ESC \.
                    while (runes.MoveNext() && runes.Current.Value != 0x07)
                        if (runes.Current.Value == 0x1B) { runes.MoveNext(); break; }
                }
            }
            else if (c is '\r' or '\n') o.Append('\n');
            else if (c >= 0x20) o.Append(runes.Current.ToString());
        }
        return [.. o.ToString().Split('\n').Select(l => l.Trim(Trimmed.ToCharArray())).Where(l => l.Length > 0)];
    }

    /// <summary>Counts and cuts by user-perceived characters, as Swift's String does.</summary>
    private readonly struct StringInfoText(string text)
    {
        private readonly System.Globalization.StringInfo _info = new(text);
        public int Length => _info.LengthInTextElements;
        public string Prefix(int count) => _info.SubstringByTextElements(0, Math.Min(count, Length));
    }
}
