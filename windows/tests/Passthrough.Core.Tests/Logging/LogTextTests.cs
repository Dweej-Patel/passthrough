using Passthrough.Core.Logging;
using Passthrough.Core.Protocol;
using Xunit;

namespace Passthrough.Core.Tests.Logging;

/// <summary>What <see cref="LogText.Redact"/> keeps out of the log, and what it leaves alone.</summary>
public class LogTextTests
{
    private const string Token = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";

    [Fact]
    public void PairingTokens_AsBefore()
    {
        Assert.Equal("token (redacted) here", LogText.Redact($"token {Token} here"));
        Assert.Equal("x" + Token, LogText.Redact("x" + Token)); // part of a longer run is not a token
    }

    [Theory]
    [InlineData("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")]
    [InlineData("q+/9AwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")]
    [InlineData("q-_9AwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")]
    public void ThirtyTwoByteKeys_InBase64(string key)
    {
        Assert.Equal("key (redacted).", LogText.Redact($"key {key}."));
    }

    [Fact]
    public void KeysAsJsonWritesThem_EscapedPlusAndSlash()
    {
        var line = System.Text.Encoding.UTF8.GetString(new ControlEnvelope("shellGrant")
        {
            ShellKey = "q+/9AwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
        }.EncodeLine());
        Assert.Contains("\\u002B", line); // what System.Text.Json writes for +
        Assert.DoesNotContain("9AwQFBgcICQoL", LogText.Redact(line));
        Assert.DoesNotContain("9AwQFBgcICQoL", LogText.Redact("q\\u002B\\/9AwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="));
    }

    [Theory]
    [InlineData("shellKey")]
    [InlineData("previousKey")]
    [InlineData("relayToken")]
    [InlineData("mac")]
    [InlineData("password")]
    public void SecretFields_InJson_WhateverTheirShape(string field)
    {
        var text = $"{{\"t\":\"x\",\"{field}\":\"short-secret-1\",\"other\":\"kept\"}}";
        var redacted = LogText.Redact(text);
        Assert.DoesNotContain("short-secret-1", redacted);
        Assert.Contains($"\"{field}\":\"(redacted)\"", redacted);
        Assert.Contains("\"other\":\"kept\"", redacted);
    }

    [Fact]
    public void BearerHeaders()
    {
        Assert.Equal("Authorization: Bearer (redacted) next", LogText.Redact("Authorization: Bearer abc.def-123 next"));
    }

    [Fact]
    public void RegisteredSecrets_PlainAndUrlEncoded_UntilUnregistered()
    {
        const string secret = "relay/token+with=chars-0193";
        LogText.Register(secret);
        try
        {
            Assert.Equal("dial (redacted) now", LogText.Redact($"dial {secret} now"));
            Assert.Equal("?t=(redacted)", LogText.Redact("?t=" + Uri.EscapeDataString(secret)));
        }
        finally { LogText.Unregister(secret); }
        Assert.Contains(secret, LogText.Redact($"dial {secret} now"));
    }

    [Fact]
    public void ShortRegisteredSecrets_OnlyAsWholeWords()
    {
        LogText.Register("q7Zk1");
        try
        {
            Assert.Equal("is (redacted).", LogText.Redact("is q7Zk1."));
            Assert.Equal("aq7Zk1b", LogText.Redact("aq7Zk1b"));
        }
        finally { LogText.Unregister("q7Zk1"); }
    }

    [Fact]
    public void PublicIdentifiers_AreLeftAlone()
    {
        var hex = new string('a', 32) + new string('0', 32); // an endpoint id or certificate hash
        Assert.Equal($"id {hex}", LogText.Redact($"id {hex}"));
        Assert.Equal("", LogText.Redact(""));
    }
}
