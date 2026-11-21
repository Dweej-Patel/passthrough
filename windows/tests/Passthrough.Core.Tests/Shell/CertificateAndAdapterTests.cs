using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Passthrough.Core.Shell;
using Passthrough.Core.Shell.Identity;
using Xunit;

namespace Passthrough.Core.Tests.Shell;

public sealed class CertificateAndAdapterTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 21, 12, 0, 0, TimeSpan.Zero);

    private static (byte[] Der, ECDsa Key) Make()
    {
        var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var q = key.ExportParameters(false).Q;
        var tbs = CertificateDer.Tbs([0x04, .. q.X!, .. q.Y!], CertificateDer.CommonName, new byte[16], Now);
        return (CertificateDer.Certificate(tbs, key.SignData(tbs, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)), key);
    }

    [Fact]
    public void TheCertificateIsWhatTheMacMakes()
    {
        var (der, key) = Make();
        using var certificate = X509CertificateLoader.LoadCertificate(der);
        Assert.Equal(3, certificate.Version);
        Assert.Equal("CN=Passthrough PC", certificate.Subject);
        Assert.Equal(certificate.Subject, certificate.Issuer);
        Assert.Empty(certificate.Extensions);
        Assert.Equal("1.2.840.10045.4.3.2", certificate.SignatureAlgorithm.Value);
        Assert.Equal(Now.AddDays(-1).UtcDateTime, certificate.NotBefore.ToUniversalTime());
        Assert.Equal(Now.AddDays(20 * 365).UtcDateTime, certificate.NotAfter.ToUniversalTime());
        // The serial is positive with no leading zero: its first byte is 0x40 even from zero bytes.
        Assert.StartsWith("40", certificate.SerialNumber, StringComparison.Ordinal);
        using var publicKey = certificate.GetECDsaPublicKey()!;
        Assert.Equal(key.ExportParameters(false).Q.X, publicKey.ExportParameters(false).Q.X);
        Assert.Equal(CertificateDer.Pin(der), Convert.ToHexStringLower(SHA256.HashData(certificate.RawData)));
    }

    [Fact]
    public void TheSignatureVerifiesWithItsOwnKey()
    {
        var (der, key) = Make();
        using var certificate = X509CertificateLoader.LoadCertificate(der);
        using var chain = new X509Chain();
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        chain.ChainPolicy.CustomTrustStore.Add(certificate);
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        chain.ChainPolicy.VerificationTime = Now.UtcDateTime;
        Assert.True(chain.Build(certificate), string.Join(", ", chain.ChainStatus.Select(s => s.StatusInformation)));
    }

    [Fact]
    public void LengthsOver127UseLongForm() => Assert.Equal(new byte[] { 0x04, 0x81, 0x80 }, CertificateDer.Tlv(0x04, new byte[128])[..3]);

    private static AdapterFacts Adapter(int type, bool hardware, bool connector, params string[] addresses) =>
        new("id", "name", type, Up: true, hardware, connector, [.. addresses.Select(a => new AdapterAddress(a, a.Contains(':') ? 64 : 24, true))]);

    [Fact]
    public void WireGuardAndWintunAreTunnels_SwitchesTapAndWwanAreNot()
    {
        Assert.True(AdapterPolicy.IsTunnel(Adapter(AdapterPolicy.IfTypePropVirtual, false, false)));   // Tailscale (Wintun)
        Assert.True(AdapterPolicy.IsTunnel(Adapter(AdapterPolicy.IfTypeTunnel, false, false)));
        Assert.False(AdapterPolicy.IsTunnel(Adapter(AdapterPolicy.IfTypeEthernet, false, false)));      // Hyper-V, WSL, TAP
        Assert.False(AdapterPolicy.IsTunnel(Adapter(AdapterPolicy.IfTypeWwanPp, true, true)));          // a carrier's 100.64/10
        Assert.False(AdapterPolicy.IsTunnel(Adapter(AdapterPolicy.IfTypePropVirtual, true, false)));
    }

    [Fact]
    public void ATailscaleAddressIsAnOverlayOnlyOnItsTunnel()
    {
        var addresses = AdapterPolicy.LocalAddresses([
            Adapter(AdapterPolicy.IfTypeWifi, true, true, "192.168.1.20"),
            Adapter(AdapterPolicy.IfTypePropVirtual, false, false, "100.101.102.103"),
            Adapter(AdapterPolicy.IfTypeWwanPp, true, true, "100.64.9.9"),
        ]);
        Assert.True(addresses.Single(a => a.Address == "100.101.102.103").IsOverlayTunnel);
        Assert.False(addresses.Single(a => a.Address == "100.64.9.9").IsOverlayTunnel);
        Assert.True(ShellAddressPolicy.ArrivedOnItsNetwork("100.90.1.1", "100.101.102.103", () => addresses));
        Assert.False(ShellAddressPolicy.ArrivedOnItsNetwork("100.90.1.1", "192.168.1.20", () => addresses));
    }

    [Fact]
    public void GrantsAdvertiseReachableAddressesOnly()
    {
        var advertised = AdapterPolicy.Advertised([
            Adapter(AdapterPolicy.IfTypePropVirtual, false, false, "100.101.102.103"),
            Adapter(AdapterPolicy.IfTypeWifi, true, true, "192.168.1.20", "fe80::1"),
            Adapter(AdapterPolicy.IfTypeEthernet, false, false, "172.25.80.1"),   // the WSL switch
            Adapter(AdapterPolicy.IfTypeLoopback, false, false, "127.0.0.1"),
        ]);
        Assert.Equal(["192.168.1.20", "100.101.102.103"], advertised);
    }

    [Fact]
    public void OnLinkPrefixesComeFromRealAdaptersOnly()
    {
        var prefixes = AdapterPolicy.OnLinkPrefixes([
            Adapter(AdapterPolicy.IfTypeWifi, true, true, "2001:db8:1:2::20"),
            Adapter(AdapterPolicy.IfTypePropVirtual, false, false, "fd7a:115c:a1e0::1"),
        ]);
        Assert.Single(prefixes);
    }
}
