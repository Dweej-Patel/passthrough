using Passthrough.Core.Session;

namespace Passthrough.Core.Presentation;

/// <summary>Keeps a list of row objects in step with the session's phones.</summary>
public static class RowList
{
    /// <summary>
    /// Updates each phone's existing row in place (so a code being typed survives status ticks) and makes rows for new
    /// phones. When phones come, go or change order, the list is edited one row at a time (remove, insert), never cleared:
    /// a bound list view rebuilds only the rows that changed, so a code box being typed in keeps its focus when another
    /// phone is plugged in. True when the list changed.
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

        var kept = next.ToHashSet(ReferenceEqualityComparer.Instance);
        for (var i = rows.Count - 1; i >= 0; i--)
            if (!kept.Contains(rows[i])) rows.RemoveAt(i);
        for (var i = 0; i < next.Count; i++)
        {
            if (i < rows.Count && ReferenceEquals(rows[i], next[i])) continue;
            // Out of place (moved) or new: take it out where it is, if anywhere, and put it here.
            for (var j = i + 1; j < rows.Count; j++)
            {
                if (!ReferenceEquals(rows[j], next[i])) continue;
                rows.RemoveAt(j);
                break;
            }
            rows.Insert(i, next[i]);
        }
        return true;
    }
}
