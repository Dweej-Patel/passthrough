using Passthrough.Core.Transport;

namespace Passthrough.App;

/// <summary>Pictures from the Windows symbol font (Segoe Fluent Icons, or Segoe MDL2 Assets on Windows 10: the same code points).</summary>
internal static class Glyphs
{
    public const string Phone = "";
    public const string Tablet = "";

    /// <summary>A tablet for an iPad, a phone for the rest and for "no phone".</summary>
    public static string For(PhoneKind? kind) => kind == PhoneKind.IPad ? Tablet : Phone;
}
