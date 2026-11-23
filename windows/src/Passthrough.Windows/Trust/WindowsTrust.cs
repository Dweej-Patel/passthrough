using System.Runtime.InteropServices.WindowsRuntime;
using System.Security.Cryptography;
using Passthrough.Core.Trust;
using Windows.Security.Credentials;

namespace Passthrough.Windows.Trust;

/// <summary>
/// Windows Hello's key for this account (<c>KeyCredentialManager</c>, the documented surface for a desktop app; a PIN
/// is enough): RSA-2048 held by Hello, made on first use (one prompt), each signature asked with Hello.
/// </summary>
public sealed class HelloSigner : IHelloSigner
{
    public const string KeyName = "Passthrough.Computers.v1";

    public async Task<bool> IsAvailableAsync()
    {
        try { return await KeyCredentialManager.IsSupportedAsync(); }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException) { return false; }
    }

    public async Task<byte[]?> SignAsync(byte[] challenge)
    {
        try
        {
            var opened = await KeyCredentialManager.OpenAsync(KeyName);
            if (opened.Status == KeyCredentialStatus.NotFound)
                opened = await KeyCredentialManager.RequestCreateAsync(KeyName, KeyCredentialCreationOption.FailIfExists);
            if (opened.Status != KeyCredentialStatus.Success) return null;
            var signed = await opened.Credential.RequestSignAsync(challenge.AsBuffer());
            return signed.Status == KeyCredentialStatus.Success ? signed.Result.ToArray() : null;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException) { return null; }
    }
}

/// <summary>
/// This account's identity key as a viewer (stage 7 §0): a persisted, non-exportable P-256 CNG key, in the Platform
/// Crypto Provider (TPM) when there is one, else the software provider. Never the service's TLS key or its iroh key.
/// </summary>
public sealed class CngComputerIdentity : IComputerIdentity, IDisposable
{
    public const string KeyName = "Passthrough.Computer.Identity.v1";
    private readonly CngKey _key;
    private readonly ECDsaCng _ecdsa;

    private CngComputerIdentity(CngKey key)
    {
        _key = key;
        _ecdsa = new ECDsaCng(key);
        var q = _ecdsa.ExportParameters(includePrivateParameters: false).Q;
        PublicKey = [0x04, .. q.X!, .. q.Y!];
    }

    public byte[] PublicKey { get; }

    public byte[] Sign(byte[] message) => _ecdsa.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);

    public static CngComputerIdentity LoadOrCreate(string keyName = KeyName)
    {
        foreach (var provider in new[] { new CngProvider("Microsoft Platform Crypto Provider"), CngProvider.MicrosoftSoftwareKeyStorageProvider })
        {
            try
            {
                if (CngKey.Exists(keyName, provider)) return new CngComputerIdentity(CngKey.Open(keyName, provider));
            }
            catch (CryptographicException) { }
        }
        foreach (var provider in new[] { new CngProvider("Microsoft Platform Crypto Provider"), CngProvider.MicrosoftSoftwareKeyStorageProvider })
        {
            try
            {
                return new CngComputerIdentity(CngKey.Create(CngAlgorithm.ECDsaP256, keyName, new CngKeyCreationParameters
                {
                    Provider = provider, ExportPolicy = CngExportPolicies.None, KeyUsage = CngKeyUsages.Signing,
                }));
            }
            catch (CryptographicException) { } // no TPM, or it refused: the software provider next
        }
        throw new CryptographicException("This PC couldn't make its identity key.");
    }

    public static void Forget(string keyName = KeyName)
    {
        foreach (var provider in new[] { new CngProvider("Microsoft Platform Crypto Provider"), CngProvider.MicrosoftSoftwareKeyStorageProvider })
        {
            try { if (CngKey.Exists(keyName, provider)) using (var key = CngKey.Open(keyName, provider)) key.Delete(); }
            catch (CryptographicException) { }
        }
    }

    public void Dispose()
    {
        _ecdsa.Dispose();
        _key.Dispose();
    }
}
