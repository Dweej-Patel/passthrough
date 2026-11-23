using System.Security.Cryptography;
using Passthrough.Core.Storage;

namespace Passthrough.Windows.Storage;

/// <summary>
/// The service's secrets: one file per slot in <c>%ProgramData%\Passthrough\store</c> (see <see cref="SecretFile"/>),
/// protected by DPAPI as the service's own account with this store's entropy, so only that account opens them; not
/// machine scope, which any local program could decrypt. The folder's security (set by the install) is the second
/// lock. Each write is flushed to the disk before it replaces the old file.
/// </summary>
public sealed class ServiceSecretStore(string folder) : ISecretStore
{
    private static readonly byte[] Entropy = "Passthrough.Service.store.v1"u8.ToArray();
    private readonly Lock _gate = new();

    public string? Get(string slot)
    {
        lock (_gate)
        {
            var path = PathFor(slot);
            if (!File.Exists(path)) return null;
            return Read(path) is { } record && record.Slot == slot ? record.Value : null;
        }
    }

    public void Set(string slot, string value)
    {
        lock (_gate)
        {
            var path = PathFor(slot);
            var temp = path + ".tmp";
            using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                stream.Write(ProtectedData.Protect(SecretFile.Encode(slot, value), Entropy, DataProtectionScope.CurrentUser));
                stream.Flush(flushToDisk: true);
            }
            File.Move(temp, path, overwrite: true);
        }
    }

    public void Delete(string slot)
    {
        lock (_gate)
        {
            try { File.Delete(PathFor(slot)); }
            catch (DirectoryNotFoundException) { }
        }
    }

    public IReadOnlyList<string> Slots()
    {
        lock (_gate)
        {
            if (!Directory.Exists(folder)) return [];
            var slots = new List<string>();
            foreach (var path in Directory.EnumerateFiles(folder, "*.bin"))
            {
                try
                {
                    if (Read(path) is { } record && string.Equals(Path.GetFileName(path), SecretFile.FileName(record.Slot), StringComparison.OrdinalIgnoreCase)) slots.Add(record.Slot);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
            slots.Sort(StringComparer.Ordinal);
            return slots;
        }
    }

    private static (string Slot, string Value)? Read(string path)
    {
        try { return SecretFile.Decode(ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser)); }
        catch (CryptographicException) { return null; }
    }

    private string PathFor(string slot) => Path.Combine(folder, SecretFile.FileName(slot));
}
