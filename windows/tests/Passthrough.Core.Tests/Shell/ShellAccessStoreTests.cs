using Passthrough.Core.Shell.Access;
using Passthrough.Core.Storage;
using Passthrough.Core.Tests.Fakes;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

/// <summary>The phone cases of ShellAccessStoreTests.swift.</summary>
public class ShellAccessStoreTests
{
    /// <summary>A secret store that can be made to fail, and counts its reads.</summary>
    private sealed class Store : ISecretStore
    {
        private readonly MemorySecretStore _inner = new();
        public bool FailWrites, FailDeletes;
        public int Reads;
        public string? Get(string slot) { Interlocked.Increment(ref Reads); return _inner.Get(slot); }
        public void Set(string slot, string value) { if (FailWrites) throw new IOException("disk full"); _inner.Set(slot, value); }
        public void Delete(string slot) { if (FailDeletes) throw new IOException("locked"); _inner.Delete(slot); }
        public IReadOnlyList<string> Slots() => _inner.Slots();
    }

    private readonly Store _secrets = new();
    private readonly FakeTimeProvider _time = new();

    private ShellAccessStore NewStore() => new(_secrets, _time);

    private ShellPhone Phone(string id = "phone-a", string slot = "token.iphone.A", byte fill = 1) =>
        new() { PhoneId = id, Label = "iPhone", PairingSlot = slot, Key = Enumerable.Repeat(fill, 32).ToArray(), GrantedAt = _time.GetUtcNow() };

    [Fact]
    public void AGrantedPhonesKeyIsAccepted_AndSurvivesANewStore()
    {
        var store = NewStore();
        Assert.True(store.Record(Phone()));
        Assert.Equal([Phone().Key], store.CandidateKeys("phone-a"));
        Assert.Empty(store.CandidateKeys("stranger"));
        Assert.Equal(["phone-a"], NewStore().Phones.Select(p => p.PhoneId));
    }

    [Fact]
    public void TheKeyBeforeANewGrantWorksUntilTheNewOneIsProved()
    {
        var store = NewStore();
        store.Record(Phone(fill: 1));
        store.Record(Phone(fill: 2));
        Assert.Equal([Phone(fill: 2).Key, Phone(fill: 1).Key], store.CandidateKeys("phone-a"));
        // Granted again before it used the second: the first is what it may still hold.
        store.Record(Phone(fill: 3));
        Assert.Equal([Phone(fill: 3).Key, Phone(fill: 1).Key], store.CandidateKeys("phone-a"));
        store.ConfirmCurrentKey("phone-a", Phone(fill: 1).Key); // not its current key: nothing changes
        Assert.Equal(2, store.CandidateKeys("phone-a").Count);
        store.ConfirmCurrentKey("phone-a", Phone(fill: 3).Key);
        Assert.Equal([Phone(fill: 3).Key], store.CandidateKeys("phone-a"));
        Assert.Equal([Phone(fill: 3).Key], NewStore().CandidateKeys("phone-a"));
    }

    [Fact]
    public void AnIdFromAnotherPairingOrNotAPhonesIsRefused()
    {
        var store = NewStore();
        store.Record(Phone());
        Assert.False(store.Record(Phone(slot: "token.android.X", fill: 9)));
        Assert.Equal([Phone().Key], store.CandidateKeys("phone-a"));
        foreach (var id in new[] { "viewer.abc", "computer.abc", "", "a b", new string('a', 65) })
            Assert.False(store.Record(Phone(id: id)));
    }

    [Fact]
    public void ScreenIsOffUntilTurnedOn_AndRenewingTheKeyKeepsIt()
    {
        var store = NewStore();
        store.Record(Phone());
        Assert.False(store.ScreenAllowed("phone-a"));
        Assert.True(store.SetScreenAllowed("phone-a", true));
        store.Record(Phone(fill: 5));
        Assert.True(NewStore().ScreenAllowed("phone-a"));
        Assert.False(store.SetScreenAllowed("stranger", true));
    }

    [Fact]
    public void TakingAccessAwayHoldsEvenWhenTheStoreCantBeWritten()
    {
        var store = NewStore();
        store.Record(Phone());
        store.Record(Phone(id: "phone-b", slot: "token.android.B"));
        store.SetScreenAllowed("phone-b", true);
        _secrets.FailWrites = true;
        _secrets.FailDeletes = true;

        Assert.False(store.SetScreenAllowed("phone-b", false));
        Assert.False(store.ScreenAllowed("phone-b"), "off now, though not saved");
        var (done, removed) = store.Revoke("phone-a");
        Assert.False(done);
        Assert.Equal(["phone-a"], removed.Select(p => p.PhoneId));
        Assert.Empty(store.CandidateKeys("phone-a"));
        // Read from the store again: still gone, still off.
        _time.Advance(TimeSpan.FromMinutes(1));
        Assert.Empty(store.CandidateKeys("phone-a"));
        Assert.False(store.ScreenAllowed("phone-b"));

        // Writes work again: the next write saves both.
        _secrets.FailWrites = _secrets.FailDeletes = false;
        store.Relabel("token.android.B", "Pixel");
        var fresh = NewStore();
        Assert.Equal(["phone-b"], fresh.Phones.Select(p => p.PhoneId));
        Assert.False(fresh.ScreenAllowed("phone-b"));
    }

    [Fact]
    public void ARevokeThatCantRewriteDeletesEveryone()
    {
        var store = NewStore();
        store.Record(Phone());
        store.Record(Phone(id: "phone-b", slot: "token.android.B"));
        _secrets.FailWrites = true;
        var (done, _) = store.Revoke("phone-a");
        Assert.True(done, "deleted whole rather than left holding a revoked key");
        _secrets.FailWrites = false;
        Assert.Empty(NewStore().Phones);
    }

    [Fact]
    public void AnUnreadableListIsNeverOverwritten_AndARevokeRemovesIt()
    {
        _secrets.Set(ShellAccessStore.Slot, "{not json");
        var store = NewStore();
        Assert.Empty(store.Phones);
        Assert.False(store.Record(Phone()));
        Assert.Equal("{not json", _secrets.Get(ShellAccessStore.Slot));
        Assert.True(store.RevokeSlot("token.iphone.A").Done);
        Assert.Null(_secrets.Get(ShellAccessStore.Slot));
    }

    [Fact]
    public void RevokingASlotRemovesItsPhonesOnly()
    {
        var store = NewStore();
        store.Record(Phone());
        store.Record(Phone(id: "phone-b", slot: "token.android.B"));
        var (done, removed) = store.RevokeSlot("token.android.B");
        Assert.True(done);
        Assert.Equal(["phone-b"], removed.Select(p => p.PhoneId));
        Assert.Equal(["phone-a"], NewStore().Phones.Select(p => p.PhoneId));
        Assert.Empty(store.RevokeSlot("token.android.B").Removed);
    }

    [Fact]
    public void StrangersHandshakesDontEachReadTheStore()
    {
        var store = NewStore();
        for (var i = 0; i < 50; i++) Assert.Empty(store.CandidateKeys($"stranger-{i}"));
        Assert.Equal(1, _secrets.Reads);
        _time.Advance(ShellAccessStore.EmptyTtl);
        store.CandidateKeys("stranger");
        Assert.Equal(2, _secrets.Reads);
        // A phone stored by another writer is seen once the empty answer expires.
        NewStore().Record(Phone());
        _time.Advance(ShellAccessStore.EmptyTtl);
        Assert.NotEmpty(store.CandidateKeys("phone-a"));
    }

    [Fact]
    public void ChangesAreAnnounced()
    {
        var store = NewStore();
        var changes = 0;
        store.Changed += () => changes++;
        store.Record(Phone());
        store.SetScreenAllowed("phone-a", true);
        store.Relabel("token.iphone.A", "Work iPhone");
        store.Revoke("phone-a");
        Assert.Equal(4, changes);
    }
    [Fact]
    public void APhonesChosenNameIsCleanedBeforeItIsShownOrLogged()
    {
        static string S(params int[] codes) => string.Concat(codes.Select(c => char.ConvertFromUtf32(c)));
        // A right-to-left override, a line separator, a NUL, a zero-width space and a bell are all taken out.
        Assert.Equal("Jane's iPhone", ShellAccessStore.CleanLabel("Jane's" + S(0x202E) + " iPhone" + S(13, 10)));
        Assert.Equal("fake log line", ShellAccessStore.CleanLabel("fake" + S(10) + "log" + S(0x2028) + "line" + S(0)));
        Assert.Equal("A phone", ShellAccessStore.CleanLabel(S(0x200B, 7)));
        Assert.Equal(ShellAccessStore.MaxLabel, ShellAccessStore.CleanLabel(new string('e', 200)).Length);
        var store = NewStore();
        store.Record(Phone() with { Label = "Evil" + S(0x202E) + "enohPi" });
        Assert.Equal("EvilenohPi", store.Phones.Single().Label);
    }
}
