using System.Text;

namespace Passthrough.Core.Shell.Sessions;

/// <summary>
/// A Windows command line from a program and its arguments, quoted so the C runtime's parser (and
/// CommandLineToArgvW) reads back exactly those arguments: the rules in "Parsing C++ command-line arguments".
/// Only the host's own catalog supplies arguments; quoting them right still matters for paths with spaces.
/// </summary>
public static class CommandLine
{
    public static string Build(string executable, IEnumerable<string> arguments)
    {
        if (executable.Contains('"')) throw new ArgumentException("a program path can't hold a quote", nameof(executable));
        var o = new StringBuilder();
        // The program name is read up to the next quote (when quoted) with no escapes: quote it whole.
        o.Append('"').Append(executable).Append('"');
        foreach (var argument in arguments)
        {
            o.Append(' ');
            Append(o, argument);
        }
        return o.ToString();
    }

    private static void Append(StringBuilder o, string argument)
    {
        if (argument.Length > 0 && argument.IndexOfAny([' ', '\t', '\n', '\v', '"']) < 0)
        {
            o.Append(argument);
            return;
        }
        o.Append('"');
        var backslashes = 0;
        foreach (var c in argument)
        {
            if (c == '\\') { backslashes++; continue; }
            // Backslashes before a quote are doubled, and the quote escaped; elsewhere they are literal.
            o.Append('\\', c == '"' ? backslashes * 2 + 1 : backslashes);
            backslashes = 0;
            o.Append(c);
        }
        // Before the closing quote, they are doubled too.
        o.Append('\\', backslashes * 2);
        o.Append('"');
    }

    /// <summary>
    /// A CreateProcess environment block: <c>NAME=value</c> entries sorted by name without regard to case, each
    /// ending in NUL, then a final NUL. Names holding <c>=</c> (beyond the drive-letter entries' leading one) or NUL are refused.
    /// </summary>
    public static string EnvironmentBlock(IReadOnlyDictionary<string, string> environment)
    {
        var o = new StringBuilder();
        foreach (var (name, value) in environment.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (name.Length == 0 || name.IndexOf('=', 1) >= 0 || name.Contains('\0') || value.Contains('\0'))
                throw new ArgumentException($"not an environment variable: {name}", nameof(environment));
            o.Append(name).Append('=').Append(value).Append('\0');
        }
        if (o.Length == 0) o.Append('\0');
        o.Append('\0');
        return o.ToString();
    }
}
