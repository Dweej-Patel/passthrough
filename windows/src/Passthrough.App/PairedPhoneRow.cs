using Passthrough.Core.Presentation;

namespace Passthrough.App;

/// <summary>
/// One stored pairing as Settings shows it: Core's <see cref="PairedPhone"/> behind read-only properties. The XAML
/// compiler writes a setter for every settable property of a bound type, and a record's init-only ones don't compile
/// there, so the list binds to this instead of the record.
/// </summary>
public sealed class PairedPhoneRow(PairedPhone phone)
{
    public string Slot => phone.Slot;
    public string Title => phone.Title;
    public string Detail => phone.Detail;

    /// <summary>A tablet for an iPad's pairing, a phone for the rest.</summary>
    public string Glyph => phone.Slot.StartsWith("token.ipad.", StringComparison.Ordinal) ? Glyphs.Tablet : Glyphs.Phone;
}
