using Passthrough.Core.Session;

namespace Passthrough.Core.Presentation;

/// <summary>Keeps a list of row objects in step with the session's phones.</summary>
public static class RowList
{
    /// <summary>
    /// Updates each phone's existing row in place (so a code being typed survives status ticks) and makes rows for new
    /// phones. The list itself is cleared and refilled only when the phones or their order changed, so rows being edited
    /// are left alone otherwise. True when the list was rebuilt.
    /// </summary>
    public static bool Reconcile<TRow>(IList<TRow> rows, IReadOnlyList<PhoneEntry> phones, Func<TRow, string> id,
        Func<PhoneEntry, TRow> create, Action<TRow, PhoneEntry> update) where TRow : class
    {
        var existing = rows.ToDictionary(id);
        var next = new List<TRow>(phones.Count);
        foreach (var entry in phones)
        {
            if (existing.TryGetValue(entry.Device.Id, out var row)) update(row, entry);
            else row = create(entry);
            next.Add(row);
        }
        if (next.SequenceEqual(rows, ReferenceEqualityComparer.Instance)) return false;
        rows.Clear();
        foreach (var row in next) rows.Add(row);
        return true;
    }
}
