using Passthrough.Core.Control;
using Passthrough.Core.Presentation;
using Passthrough.Core.Session;
using Passthrough.Core.Transport;
using Xunit;

namespace Passthrough.Core.Tests.Presentation;

public class RowListTests
{
    private sealed class Row(PhoneEntry e)
    {
        public PhoneEntry Entry = e;
        public string Id => Entry.Device.Id;
    }

    private static PhoneEntry E(string id, PhoneState state = PhoneState.NotPaired) =>
        new(new PhoneDevice(id, PhoneKind.Android, id, "token.android." + id, WatchTransport.Adb, (_, _) => throw new InvalidOperationException()),
            state, false, null, 0, 0, 0, null, false, 1);

    private static bool Sync(List<Row> rows, params PhoneEntry[] phones) =>
        RowList.Reconcile(rows, phones, r => r.Id, e => new Row(e), (r, e) => r.Entry = e);

    [Fact]
    public void SamePhones_RowsKeptInPlaceAndUpdated()
    {
        var rows = new List<Row>();
        Assert.True(Sync(rows, E("a"), E("b")));
        var (a, b) = (rows[0], rows[1]);

        Assert.False(Sync(rows, E("a", PhoneState.Paired), E("b")));
        Assert.Same(a, rows[0]);
        Assert.Same(b, rows[1]);
        Assert.Equal(PhoneState.Paired, a.Entry.State);
    }

    [Fact]
    public void PhoneAddedOrRemoved_ListRebuilt_ExistingRowsReused()
    {
        var rows = new List<Row>();
        Sync(rows, E("a"), E("b"));
        var b = rows[1];

        Assert.True(Sync(rows, E("b"), E("c")));
        Assert.Equal(["b", "c"], rows.Select(r => r.Id));
        Assert.Same(b, rows[0]);

        Assert.True(Sync(rows));
        Assert.Empty(rows);
    }
}
