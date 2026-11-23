using Passthrough.Core.Session;
using Passthrough.Core.Shell.Access;
using Xunit;
using static Passthrough.Core.Session.ShellGrantLedger;

namespace Passthrough.Core.Tests.Session;

/// <summary>A port of the ShellGrantLedger tests in MacSessionPolicyTests.swift, case for case.</summary>
public class ShellGrantLedgerTests
{
    private static readonly string A1 = new GrantContents { CertSHA256 = "c1", HostName = "PC" }.Fingerprint;
    private static readonly string A2 = new GrantContents { CertSHA256 = "c1", HostName = "PC", IrohId = new string('a', 64) }.Fingerprint;
    private static readonly DateTimeOffset T0 = new(2026, 11, 21, 12, 0, 0, TimeSpan.Zero);

    private static TimeSpan S(double seconds) => TimeSpan.FromSeconds(seconds);

    [Fact]
    public void GrantOncePerCableConnection()
    {
        var ledger = new ShellGrantLedger();
        Assert.True(ledger.ShouldGrant("a", A1, T0));
        ledger.Sent("a", A1, "g1");
        Assert.False(ledger.ShouldGrant("a", A1, T0)); // no second grant while one is in flight
        Assert.Equal("g1", ledger.InFlightGrantId("a"));
        Assert.True(ledger.Confirmed("a", "g1"));
        Assert.False(ledger.ShouldGrant("a", A1, T0)); // retries don't re-grant
        Assert.True(ledger.ShouldGrant("b", A1, T0));
        ledger.Detached("a");
        Assert.True(ledger.ShouldGrant("a", A1, T0)); // a new cable connection grants again
    }

    [Fact]
    public void ChangedContentsGrantAgain()
    {
        var ledger = new ShellGrantLedger();
        ledger.Sent("a", A1, "g1");
        ledger.Confirmed("a", "g1");
        Assert.NotEqual(A1, A2);
        Assert.True(ledger.ShouldGrant("a", A2, T0)); // the iroh endpoint came up
        ledger.Sent("a", A2, "g2");
        ledger.Confirmed("a", "g2");
        Assert.False(ledger.ShouldGrant("a", A2, T0));
        Assert.True(ledger.ShouldGrant("a", A1, T0)); // the endpoint went away again
    }

    [Fact]
    public void NoBackToBackGrants()
    {
        var ledger = new ShellGrantLedger();
        ledger.Sent("a", A1, "g1");
        Assert.False(ledger.ShouldGrant("a", A2, T0)); // contents changed mid-flight: wait for the answer
        Assert.False(ledger.Confirmed("a", "other")); // an answer to another grant records nothing
        Assert.False(ledger.ShouldGrant("a", A2, T0));
        Assert.True(ledger.Confirmed("a", "g1"));
        Assert.True(ledger.ShouldGrant("a", A2, T0));
        Assert.False(ledger.ShouldGrant("a", A1, T0));
    }

    [Fact]
    public void AnswerMatching()
    {
        Assert.True(AnswerMatches(null, "g1")); // phones before grant ids
        Assert.True(AnswerMatches("g1", "g1"));
        Assert.False(AnswerMatches("g0", "g1"));
    }

    [Fact]
    public void UnansweredGrantIsRetriedOnNextChannel()
    {
        var ledger = new ShellGrantLedger();
        ledger.Sent("a", A1, "g1");
        ledger.ChannelClosed("a");
        Assert.True(ledger.ShouldGrant("a", A1, T0));
        Assert.False(ledger.Confirmed("a", "g1")); // a late answer from the closed channel records nothing
    }

    [Fact]
    public void ResetGrantsAgain()
    {
        var ledger = new ShellGrantLedger();
        ledger.Sent("a", A1, "g1");
        ledger.Confirmed("a", "g1");
        ledger.Reset();
        Assert.True(ledger.ShouldGrant("a", A1, T0));
    }

    [Fact]
    public void RevokeHoldsOnlyThatDevice()
    {
        var ledger = new ShellGrantLedger();
        ledger.Sent("a", A1, "g1");
        ledger.Revoked("a");
        Assert.False(ledger.Confirmed("a", "g1"));
        Assert.False(ledger.ShouldGrant("a", A1, T0));
        Assert.False(ledger.ShouldGrant("a", A2, T0)); // not even when the contents change
        Assert.True(ledger.IsHeld("a"));
        Assert.True(ledger.ShouldGrant("b", A1, T0));
        ledger.ChannelOpened("b");
        Assert.True(ledger.IsHeld("a")); // another phone's channel doesn't lift the hold
        ledger.ChannelOpened("a");
        Assert.True(ledger.ShouldGrant("a", A1, T0)); // a new channel (re-plug) grants again
    }

    [Fact]
    public void PairingLiftsRevokeHold()
    {
        var ledger = new ShellGrantLedger();
        ledger.Revoked("a");
        ledger.Paired("a");
        Assert.True(ledger.ShouldGrant("a", A1, T0));
        ledger.Revoked("a");
        ledger.Detached("a");
        Assert.True(ledger.ShouldGrant("a", A1, T0));
    }

    [Fact]
    public void UnansweredGrantExpires()
    {
        var ledger = new ShellGrantLedger();
        ledger.Sent("a", A1, "g1");
        Assert.False(ledger.ShouldGrant("a", A2, T0));
        Assert.IsType<Expiry.Stale>(ledger.Expired("a", "other", T0)); // only the grant still in flight expires
        Assert.Equal(new Expiry.Retry(S(15), true), ledger.Expired("a", "g1", T0));
        Assert.True(ledger.ShouldGrant("a", A2, T0)); // a lost grant no longer blocks other contents
        Assert.False(ledger.ShouldGrant("a", A1, T0)); // the same contents wait out the back-off
        Assert.True(ledger.ShouldGrant("a", A1, T0 + S(15)));
        Assert.False(ledger.Confirmed("a", "g1")); // a very late answer records nothing
        ledger.Sent("a", A1, "g2");
        ledger.Confirmed("a", "g2");
        Assert.IsType<Expiry.Stale>(ledger.Expired("a", "g2", T0)); // an answered grant does not expire
        Assert.False(ledger.ShouldGrant("a", A1, T0));
        Assert.Equal(S(15), AnswerTimeout);
    }

    private static Expiry TimeOut(ShellGrantLedger ledger, string id, string contents, DateTimeOffset now)
    {
        ledger.Sent("a", contents, id);
        return ledger.Expired("a", id, now);
    }

    [Fact]
    public void UnansweredGrantsBackOffThenRetrySlowly()
    {
        var ledger = new ShellGrantLedger();
        var now = T0;
        var outcomes = new List<Expiry>();
        for (int i = 0; i < 7; i++)
        {
            Assert.True(ledger.ShouldGrant("a", A1, now), $"grant {i}");
            var expiry = TimeOut(ledger, $"g{i}", A1, now);
            outcomes.Add(expiry);
            if (expiry is Expiry.Retry r)
            {
                Assert.False(ledger.ShouldGrant("a", A1, now + r.After - S(1)), $"still waiting after grant {i}");
                now += r.After;
            }
        }
        Assert.Equal(
            new Expiry[]
            {
                new Expiry.Retry(S(15), true), new Expiry.Retry(S(30), false), new Expiry.Retry(S(60), false), new Expiry.Retry(S(120), false),
                new Expiry.Retry(S(600), false), new Expiry.Retry(S(600), false), new Expiry.Retry(S(600), false),
            }, outcomes);
        Assert.Equal(S(600), SlowRetryDelay);
        Assert.True(ledger.ShouldGrant("b", A1, now)); // other phones are unaffected
    }

    [Fact]
    public void SlowRetriesEndOnChannelPairingContentsOrAnswer()
    {
        ShellGrantLedger SlowRetrying()
        {
            var ledger = new ShellGrantLedger();
            var now = T0;
            for (int i = 0; i < 5; i++)
                if (TimeOut(ledger, $"g{i}", A1, now) is Expiry.Retry r) now += r.After;
            Assert.False(ledger.ShouldGrant("a", A1, T0));
            return ledger;
        }

        var l = SlowRetrying();
        l.ChannelOpened("a");
        Assert.True(l.ShouldGrant("a", A1, T0));
        Assert.Equal(new Expiry.Retry(S(15), true), TimeOut(l, "n", A1, T0));

        l = SlowRetrying();
        l.Paired("a");
        Assert.True(l.ShouldGrant("a", A1, T0));

        l = SlowRetrying();
        l.Detached("a");
        Assert.True(l.ShouldGrant("a", A1, T0));

        l = SlowRetrying();
        Assert.True(l.ShouldGrant("a", A2, T0)); // new contents go out
        Assert.Equal(new Expiry.Retry(S(15), true), TimeOut(l, "c", A2, T0)); // with a new streak

        // An answer ends the streak: the next run of timeouts starts at 15 s again.
        l = new ShellGrantLedger();
        _ = TimeOut(l, "x1", A1, T0);
        _ = TimeOut(l, "x2", A1, T0 + S(15));
        l.Sent("a", A1, "x3");
        Assert.True(l.Confirmed("a", "x3"));
        Assert.Equal(new Expiry.Retry(S(15), true), TimeOut(l, "y", A1, T0)); // a new streak, not the third step
    }

    [Fact]
    public void ContentsFingerprintIsUnambiguous()
    {
        var x = new GrantContents { CertSHA256 = "ab", Port = 1, HostName = "c" };
        var y = new GrantContents { CertSHA256 = "a", Port = 1, HostName = "bc" };
        Assert.NotEqual(x.Fingerprint, y.Fingerprint);
        var t1 = new GrantContents { CertSHA256 = "c", Port = 1, HostName = "m", IrohId = "i", IrohRelay = "r", RelayToken = "t1" };
        Assert.NotEqual(t1.Fingerprint, (t1 with { RelayToken = "t2" }).Fingerprint); // a new relay token is a new grant
        Assert.False(AnswerMatches("", "g2"));
    }
}
