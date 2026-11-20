namespace Passthrough.Core.Presentation;

/// <summary>The six-digit code as typed into the flyout.</summary>
public static class PairingCode
{
    /// <summary>Longest text the code box accepts: six digits with room for spaces or a dash, as pasted.</summary>
    public const int MaxTyped = 12;

    /// <summary>The code with spaces, dashes and other non-digits taken out, when six ASCII digits remain; otherwise null.</summary>
    public static string? Normalize(string? typed)
    {
        if (typed is null) return null;
        if (typed.Any(c => char.IsDigit(c) && !char.IsAsciiDigit(c))) return null;
        var digits = new string([.. typed.Where(char.IsAsciiDigit)]);
        return digits.Length == 6 ? digits : null;
    }
}
