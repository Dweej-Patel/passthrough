using Passthrough.Core.Storage;
using Xunit;

namespace Passthrough.Core.Tests.Storage;

public class MemorySecretStoreTests
{
    [Fact]
    public void Slots_ListsWhatIsStored_InOrder()
    {
        var store = new MemorySecretStore();
        store.Set("token.iphone.B", "b");
        store.Set("token.android.A", "a");
        store.Set("token.ipad.C", "c");
        store.Delete("token.ipad.C");
        store.Delete("token.ipad.C"); // a second delete is not an error

        Assert.Equal(["token.android.A", "token.iphone.B"], store.Slots());
    }
}
