using System.Text.RegularExpressions;

namespace Passthrough.Core.Logging;

/// <summary>
/// Keeps secrets out of log text. Nothing the app logs should carry one; this catches one that slips into an
/// exception message or a logged line. What it removes:
/// <list type="bullet">
/// <item>a run of exactly 43 URL-safe base64 characters (a pairing token);</item>
/// <item>a 32-byte value in standard or URL-safe base64 (43 characters and <c>=</c>: a shell key, an iroh
/// secret key), also with <c>+</c> and <c>/</c> as JSON writes them (<c>+</c>, <c>/</c>, <c>\/</c>);</item>
/// <item>the value of a secret-bearing field in JSON text, whatever its shape (<see cref="SecretFields"/>);</item>
/// <item><c>Authorization: Bearer …</c>;</item>
/// <item>any string registered with <see cref="Register"/> (the relay token, as typed and URL-encoded).</item>
/// </list>
/// A run of 64 hex digits is left alone: endpoint ids and certificate hashes are public and useful in a log.
/// So no secret is ever written as hex, anywhere.
/// </summary>
public static partial class LogText
{
    private const string Replacement = "(redacted)";

    /// <summary>JSON field names whose value is a secret. A stage that adds such a field adds its name here.</summary>
    public static readonly IReadOnlyList<string> SecretFields =
        ["shellKey", "key", "previousKey", "linkKey", "secretKey", "relayToken", "token", "mac", "proof", "password", "code"];

    private static readonly Lock RegisteredLock = new();
    private static readonly List<string> Registered = [];

    public static string Redact(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        string[] secrets;
        lock (RegisteredLock) secrets = [.. Registered];
        foreach (var secret in secrets)
            text = secret.Length >= 8
                ? text.Replace(secret, Replacement, StringComparison.Ordinal)
                : Regex.Replace(text, $@"(?<![A-Za-z0-9_-]){Regex.Escape(secret)}(?![A-Za-z0-9_-])", Replacement);
        text = SecretField().Replace(text, m => $"\"{m.Groups["name"].Value}\":\"{Replacement}\"");
        text = Bearer().Replace(text, "Bearer " + Replacement);
        text = KeyShape().Replace(text, Replacement);
        return TokenShape().Replace(text, Replacement);
    }

    /// <summary>
    /// Adds an exact secret that <see cref="Redact"/> removes wherever it appears, until <see cref="Unregister"/>; none
    /// is ever dropped to make room. Register a secret when it is loaded, before anything that might log it runs, and
    /// unregister the old one when it changes.
    /// </summary>
    public static void Register(string secret)
    {
        if (string.IsNullOrEmpty(secret)) return;
        var forms = new[] { secret, Uri.EscapeDataString(secret) }.Distinct();
        lock (RegisteredLock)
            foreach (var form in forms)
            {
                if (!Registered.Contains(form)) Registered.Add(form);
            }
    }

    /// <summary>Forgets a secret given to <see cref="Register"/> (both its forms).</summary>
    public static void Unregister(string secret)
    {
        if (string.IsNullOrEmpty(secret)) return;
        lock (RegisteredLock)
        {
            Registered.Remove(secret);
            Registered.Remove(Uri.EscapeDataString(secret));
        }
    }

    [GeneratedRegex("(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])")]
    private static partial Regex TokenShape();

    [GeneratedRegex(@"(?<![A-Za-z0-9+/_-])(?:[A-Za-z0-9_-]|\+|/|\\u002[BbFf]|\\/){43}=(?![A-Za-z0-9+/=_-])")]
    private static partial Regex KeyShape();

    [GeneratedRegex(@"""(?<name>shellKey|key|previousKey|linkKey|secretKey|relayToken|token|mac|proof|password|code)""\s*:\s*""(?:[^""\\]|\\.)*""")]
    private static partial Regex SecretField();

    [GeneratedRegex(@"Bearer\s+\S+", RegexOptions.IgnoreCase)]
    private static partial Regex Bearer();
}
