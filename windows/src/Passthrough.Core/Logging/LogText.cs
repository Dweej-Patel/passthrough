using System.Text.RegularExpressions;

namespace Passthrough.Core.Logging;

/// <summary>Keeps secrets out of log text.</summary>
public static partial class LogText
{
    /// <summary>
    /// Replaces every run of exactly 43 URL-safe base64 characters (the shape of a pairing token) with "(redacted)".
    /// Nothing the app logs should carry a token; this catches one that slips into an exception message.
    /// </summary>
    public static string Redact(string text) => TokenShape().Replace(text, "(redacted)");

    [GeneratedRegex("(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])")]
    private static partial Regex TokenShape();
}
