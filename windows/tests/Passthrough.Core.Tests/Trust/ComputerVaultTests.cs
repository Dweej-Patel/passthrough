using System.Security.Cryptography;
using Passthrough.Core.Shell;
using Passthrough.Core.Storage;
using Passthrough.Core.Trust;
using Xunit;

namespace Passthrough.Core.Tests.Trust;

public sealed class ComputerVaultTests
{
    /// <summary>Hello as a deterministic signer (an HMAC with a secret only it holds), or one the person declines.</summary>
    private sealed class FakeHello(byte[] secret, bool available = true, bool confirms = true) : IHelloSigner
    {
        public int Prompts;
        public Task<bool> IsAvailableAsync() => Task.FromResult(available);
        public Task<byte[]?> SignAsync(byte[] challenge)
        {
            Prompts++;
            return Task.FromResult(confirms ? HMACSHA256.HashData(secret, challenge) : null);
        }
    }

    private static ReachableComputer Computer(string host = "mac-1", string pin = "", string? iroh = null) => new()
    {
        Credential = new ShellCredentialWire
        {
            MacID = host, MacName = "MacBook", CertSHA256 = pin.Length > 0 ? pin : new string('c', 64),
            ShellKey = Convert.ToBase64String(new byte[32]), PhoneID = "computer.11111111-2222-3333-4444-555555555555", Port = 7893, IrohID = iroh,
        },
        Scopes = ["shell"], From = "iPhone", ReceivedAt = DateTimeOffset.UtcNow,
    };

    [Fact]
    public async Task KeptBehindHelloAndOpenedWithOneConfirmation()
    {
        var secrets = new MemorySecretStore();
        var hello = new FakeHello([1, 2, 3]);
        Assert.Equal(ComputerReachStore.SaveResult.Saved, await new ComputerReachStore(secrets, hello).SaveAsync(Computer()));
        // Nothing readable is stored: the slot holds only a sealed box.
        Assert.DoesNotContain("MacBook", secrets.Get(ComputerReachStore.Slot)!, StringComparison.Ordinal);
        var again = new ComputerReachStore(secrets, hello);
        Assert.True(await again.UnlockAsync());
        Assert.Equal("MacBook", again.Computers!.Single().Credential.MacName);
        Assert.True(await again.UnlockAsync());
        Assert.Equal(2, hello.Prompts); // once per store opened, not per read
    }

    [Fact]
    public async Task AnotherHelloOrADeclinedOneOpensNothing()
    {
        var secrets = new MemorySecretStore();
        await new ComputerReachStore(secrets, new FakeHello([1])).SaveAsync(Computer());
        Assert.False(await new ComputerReachStore(secrets, new FakeHello([2])).UnlockAsync());
        Assert.False(await new ComputerReachStore(secrets, new FakeHello([1], confirms: false)).UnlockAsync());
        Assert.Equal(ComputerReachStore.SaveResult.Locked, await new ComputerReachStore(new MemorySecretStore(), new FakeHello([1], available: false)).SaveAsync(Computer()));
    }

    [Fact]
    public async Task WithoutHelloTheFallbackSealsIt_AndKeepsOpeningItOnceHelloIsSetUp()
    {
        var secrets = new MemorySecretStore();
        var password = new FakeHello([9]);
        Assert.Equal(ComputerReachStore.SaveResult.Saved, await new ComputerReachStore(secrets, new FakeHello([1], available: false), password).SaveAsync(Computer()));
        Assert.DoesNotContain("MacBook", secrets.Get(ComputerReachStore.Slot)!, StringComparison.Ordinal);
        // Hello arrives later: what the password sealed is still opened by the password, not wiped by Hello's different key.
        var hello = new FakeHello([1]);
        var later = new ComputerReachStore(secrets, hello, password);
        Assert.True(await later.UnlockAsync());
        Assert.Equal("MacBook", later.Computers!.Single().Credential.MacName);
        Assert.Equal(0, hello.Prompts);
        Assert.Equal(ComputerReachStore.SaveResult.Saved, await later.SaveAsync(Computer("mac-2")));
        var again = new ComputerReachStore(secrets, hello, password);
        Assert.True(await again.UnlockAsync());
        Assert.Equal(2, again.Computers!.Count);
        // A declined password opens nothing, and nothing is lost.
        Assert.False(await new ComputerReachStore(secrets, hello, new FakeHello([9], confirms: false)).UnlockAsync());
        Assert.NotNull(secrets.Get(ComputerReachStore.Slot));
    }

    [Fact]
    public async Task HelloIsPreferred_AndAStoreItSealedIsLeftAloneWhileHelloIsAway()
    {
        var secrets = new MemorySecretStore();
        var (hello, password) = (new FakeHello([1]), new FakeHello([9]));
        Assert.Equal(ComputerReachStore.SaveResult.Saved, await new ComputerReachStore(secrets, hello, password).SaveAsync(Computer()));
        Assert.Equal((1, 0), (hello.Prompts, password.Prompts));
        var kept = secrets.Get(ComputerReachStore.Slot);
        // Hello away (a Remote Desktop session, say): the password doesn't open it, and a hand-over doesn't replace it.
        var without = new ComputerReachStore(secrets, new FakeHello([1], available: false), password);
        Assert.False(await without.UnlockAsync());
        Assert.Equal(ComputerReachStore.SaveResult.Locked, await without.SaveAsync(Computer("mac-2")));
        Assert.Equal(kept, secrets.Get(ComputerReachStore.Slot));
        Assert.Equal(0, password.Prompts);
        // Hello back: everything is still there.
        var back = new ComputerReachStore(secrets, hello, password);
        Assert.True(await back.UnlockAsync());
        Assert.Equal("mac-1", back.Computers!.Single().HostId);
    }

    [Fact]
    public async Task AHandOverWithDifferentDetailsDoesntReplace()
    {
        var store = new ComputerReachStore(new MemorySecretStore(), new FakeHello([1]));
        Assert.Equal(ComputerReachStore.SaveResult.Saved, await store.SaveAsync(Computer(iroh: new string('1', 64))));
        Assert.Equal(ComputerReachStore.SaveResult.Conflict, await store.SaveAsync(Computer(iroh: new string('2', 64))));
        Assert.Equal(ComputerReachStore.SaveResult.Conflict, await store.SaveAsync(Computer(pin: new string('d', 64), iroh: new string('1', 64))));
        Assert.Equal(ComputerReachStore.SaveResult.Saved, await store.SaveAsync(Computer(iroh: new string('1', 64)) with { Scopes = ["shell", "screen"] }));
        Assert.Equal(["shell", "screen"], store.Computers!.Single().Scopes);
        Assert.Equal(ComputerReachStore.SaveResult.NotUsable, await store.SaveAsync(Computer() with { Credential = Computer().Credential with { PhoneID = "phone-a" } }));
    }
}
