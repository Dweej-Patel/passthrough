using System.Text;
using System.Text.Json.Nodes;
using Passthrough.Core.Protocol;
using Xunit;

namespace Passthrough.Core.Tests.Protocol;

public class FixtureTests
{
    private static readonly System.Text.Json.JsonElement Fx = Fixtures.Root;

    [Fact]
    public void Constants_MatchFixtures()
    {
        Assert.Equal(ProtocolConstants.Version, Fx.GetProperty("protocolVersion").GetInt32());
        Assert.Equal(ProtocolConstants.SocksPort, Fx.GetProperty("ports").GetProperty("socks").GetInt32());
        Assert.Equal(ProtocolConstants.ControlPort, Fx.GetProperty("ports").GetProperty("control").GetInt32());
        Assert.Equal(Fx.GetProperty("pairingCodeLifetimeSeconds").GetDouble(), ProtocolConstants.PairingCodeLifetime.TotalSeconds);
        Assert.Equal(Fx.GetProperty("unauthenticatedTimeoutSeconds").GetDouble(), ProtocolConstants.UnauthenticatedTimeout.TotalSeconds);
        Assert.Equal(5, ProtocolConstants.PingInterval.TotalSeconds);
        Assert.Equal(20, ProtocolConstants.SilenceLimit.TotalSeconds);
        Assert.Equal(262144, ProtocolConstants.MaxLineBytes);
    }

    [Fact]
    public void PairingFailures_RoundTrip()
    {
        foreach (var e in Fx.GetProperty("pairingFailures").EnumerateArray())
        {
            var s = e.GetString()!;
            Assert.Equal(s, PairingFailureWire.Parse(s).ToWire());
        }
        Assert.Equal(PairingFailure.BadCode, PairingFailureWire.Parse("whatever"));
        Assert.Equal(PairingFailure.BadCode, PairingFailureWire.Parse(null));
    }

    [Fact]
    public void Tokens_HashAndWellFormed()
    {
        foreach (var t in Fx.GetProperty("tokens").EnumerateArray())
        {
            var token = t.GetProperty("token").GetString()!;
            Assert.Equal(t.GetProperty("sha256").GetString(), PairingToken.Hash(token));
            Assert.Equal(t.GetProperty("wellFormed").GetBoolean(), PairingToken.IsWellFormed(token));
        }
    }

    [Fact]
    public void ControlAuth_Vectors()
    {
        var auth = Fx.GetProperty("controlAuth");
        Assert.Equal(ControlAuth.PhoneLabel, auth.GetProperty("phoneLabel").GetString());
        Assert.Equal(ControlAuth.MacLabel, auth.GetProperty("macLabel").GetString());
        Assert.Equal(ControlAuth.SocksLabel, auth.GetProperty("socksLabel").GetString());
        Assert.Equal(ControlAuth.NonceLength, auth.GetProperty("nonceLength").GetInt32());
        foreach (var v in auth.GetProperty("vectors").EnumerateArray())
        {
            var key = ControlAuth.Key(v.GetProperty("token").GetString()!);
            Assert.Equal(v.GetProperty("tokenSHA256").GetString(), Convert.ToHexString(key).ToLowerInvariant());
            var clientId = v.GetProperty("clientID").GetString()!;
            var macNonce = Convert.FromBase64String(v.GetProperty("macNonce").GetString()!);
            var phoneNonce = Convert.FromBase64String(v.GetProperty("phoneNonce").GetString()!);
            var phoneProof = v.GetProperty("phoneProof").GetString()!;
            var macProof = v.GetProperty("macProof").GetString()!;
            Assert.Equal(phoneProof, Convert.ToBase64String(ControlAuth.PhoneProof(key, clientId, macNonce, phoneNonce)));
            Assert.Equal(macProof, Convert.ToBase64String(ControlAuth.MacProof(key, clientId, macNonce, phoneNonce)));
            Assert.Equal(v.GetProperty("socksPassword").GetString(), ControlAuth.SocksPassword(key));
            Assert.True(ControlAuth.IsValidPhoneProof(phoneProof, key, clientId, macNonce, phoneNonce));
            Assert.False(ControlAuth.IsValidPhoneProof(macProof, key, clientId, macNonce, phoneNonce));
            Assert.False(ControlAuth.IsValidPhoneProof(null, key, clientId, macNonce, phoneNonce));
            Assert.False(ControlAuth.IsValidPhoneProof("!!notbase64", key, clientId, macNonce, phoneNonce));
        }
    }

    [Fact]
    public void Nonce_GeneratedAndDecoded()
    {
        var n = ControlAuth.Nonce();
        Assert.Equal(ControlAuth.NonceLength, n.Length);
        Assert.Equal(n, ControlAuth.DecodeNonce(Convert.ToBase64String(n)));
        Assert.Null(ControlAuth.DecodeNonce(Convert.ToBase64String(new byte[5])));
        Assert.Null(ControlAuth.DecodeNonce("???"));
        Assert.Null(ControlAuth.DecodeNonce(null));
    }

    [Fact]
    public void Messages_RoundTrip()
    {
        foreach (var m in Fx.GetProperty("messages").EnumerateArray())
        {
            var line = m.GetProperty("line").GetString()!;
            var encoded = Encoding.UTF8.GetString(ControlEnvelope.Decode(Encoding.UTF8.GetBytes(line)).EncodeLine());
            Assert.EndsWith("\n", encoded);
            Assert.True(JsonNode.DeepEquals(JsonNode.Parse(encoded.TrimEnd('\n')), JsonNode.Parse(line)), line);
        }
    }

    [Fact]
    public void Decode_IgnoresUnknownFields()
    {
        Assert.Equal("ping", ControlEnvelope.Decode("{\"t\":\"ping\",\"future\":1}"u8).T);
    }

    [Fact]
    public void Decode_NonJson_Throws()
    {
        Assert.Throws<ProtocolException>(() => ControlEnvelope.Decode("nope"u8));
        Assert.Throws<ProtocolException>(() => ControlEnvelope.Decode("{\"x\":1}"u8));
    }

    [Fact]
    public void Rates_MatchFixtures()
    {
        foreach (var r in Fx.GetProperty("rates").EnumerateArray())
        {
            var (value, unit) = Format.Rate(r.GetProperty("bytesPerSecond").GetDouble());
            Assert.Equal(r.GetProperty("value").GetString(), value);
            Assert.Equal(r.GetProperty("unit").GetString(), unit);
        }
    }

    [Fact]
    public void Durations_MatchFixtures()
    {
        foreach (var d in Fx.GetProperty("durations").EnumerateArray())
            Assert.Equal(d.GetProperty("text").GetString(), Format.Duration(TimeSpan.FromSeconds(d.GetProperty("seconds").GetDouble())));
    }
}
