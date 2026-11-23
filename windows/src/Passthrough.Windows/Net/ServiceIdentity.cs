using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Passthrough.Core.Shell.Identity;

namespace Passthrough.Windows.Net;

/// <summary>
/// The service's TLS identity (stage 4 plan, section 7): a persisted, non-exportable P-256 key in the service account's
/// own key store (Windows' TLS runs in another process and reads the key by name: an in-memory key can't serve), and
/// its certificate in <c>tls.cer</c>, built by <see cref="CertificateDer"/>. Only a missing key is ever replaced: any
/// other failure is thrown, because a new key changes what every phone pins.
/// </summary>
public sealed class ServiceIdentity : IDisposable
{
    public const string KeyName = "Passthrough.Service.TLS.v1";

    private ServiceIdentity(CngKey key, byte[] der, X509Certificate2 certificate)
    {
        Key = key;
        Der = der;
        Certificate = certificate;
    }

    public CngKey Key { get; }
    public byte[] Der { get; }
    /// <summary>The certificate with its private key, for <c>SslStream</c>.</summary>
    public X509Certificate2 Certificate { get; }
    /// <summary>What phones pin: the lowercase hex SHA-256 of the certificate.</summary>
    public string Pin => CertificateDer.Pin(Der);

    /// <summary>Loads the key and certificate, or makes what is missing (case 1 to 3); throws for anything else (case 4).</summary>
    public static ServiceIdentity LoadOrCreate(string certificateFile, string keyName = KeyName, Action<string>? log = null)
    {
        CngKey key;
        var created = false;
        if (CngKey.Exists(keyName, CngProvider.MicrosoftSoftwareKeyStorageProvider))
            key = CngKey.Open(keyName, CngProvider.MicrosoftSoftwareKeyStorageProvider);
        else
        {
            key = CngKey.Create(CngAlgorithm.ECDsaP256, keyName, new CngKeyCreationParameters
            {
                Provider = CngProvider.MicrosoftSoftwareKeyStorageProvider,
                ExportPolicy = CngExportPolicies.None,
                KeyUsage = CngKeyUsages.Signing,
                KeyCreationOptions = CngKeyCreationOptions.None,
            });
            created = true;
            log?.Invoke("tls: made this PC's key");
        }
        using var ecdsa = new ECDsaCng(key);
        var point = Point(ecdsa);
        byte[]? der = null;
        if (!created && File.Exists(certificateFile))
        {
            var stored = File.ReadAllBytes(certificateFile);
            try
            {
                using var parsed = X509CertificateLoader.LoadCertificate(stored);
                using var publicKey = parsed.GetECDsaPublicKey();
                if (publicKey is not null && Point(publicKey).AsSpan().SequenceEqual(point)) der = stored;
            }
            catch (CryptographicException) { }
        }
        if (der is null)
        {
            // A new certificate for the key: the pin changes, so phones are granted again over the cable.
            var tbs = CertificateDer.Tbs(point, CertificateDer.CommonName, RandomNumberGenerator.GetBytes(16), DateTimeOffset.UtcNow);
            der = CertificateDer.Certificate(tbs, ecdsa.SignData(tbs, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence));
            File.WriteAllBytes(certificateFile, der);
            log?.Invoke("tls: made this PC's certificate");
        }
        using var publicOnly = X509CertificateLoader.LoadCertificate(der);
        var withKey = publicOnly.CopyWithPrivateKey(new ECDsaCng(key));
        return new ServiceIdentity(key, der, withKey);
    }

    /// <summary>Deletes the key (Reset identity, in the service; removal deletes the whole profile instead).</summary>
    public static void Forget(string certificateFile, string keyName = KeyName)
    {
        if (CngKey.Exists(keyName, CngProvider.MicrosoftSoftwareKeyStorageProvider))
            using (var key = CngKey.Open(keyName, CngProvider.MicrosoftSoftwareKeyStorageProvider)) key.Delete();
        if (File.Exists(certificateFile)) File.Delete(certificateFile);
    }

    private static byte[] Point(ECDsa ecdsa)
    {
        var p = ecdsa.ExportParameters(includePrivateParameters: false).Q;
        return [0x04, .. p.X!, .. p.Y!];
    }

    public void Dispose()
    {
        Certificate.Dispose();
        Key.Dispose();
    }
}
