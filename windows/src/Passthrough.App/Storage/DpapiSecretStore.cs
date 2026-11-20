using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Passthrough.Core.Storage;

namespace Passthrough.App.Storage;

/// <summary>
/// One DPAPI-protected file per slot (<c>&lt;folder&gt;\&lt;hash of slot&gt;.bin</c>, see <see cref="SecretFile"/>),
/// readable only by the current Windows user. The file holds the slot name beside the secret, so slots can be listed
/// and a file is used only for its own slot.
/// </summary>
public sealed class DpapiSecretStore : ISecretStore
{
    private readonly string _folder;
    private readonly object _gate = new();

    public DpapiSecretStore(string folder)
    {
        _folder = folder;
        EnsureFolder();
    }

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
            EnsureFolder();
            var path = PathFor(slot);
            var temp = path + ".tmp";
            File.WriteAllBytes(temp, ProtectedData.Protect(SecretFile.Encode(slot, value), null, DataProtectionScope.CurrentUser));
            File.Move(temp, path, overwrite: true);
        }
    }

    public void Delete(string slot)
    {
        lock (_gate)
        {
            // File.Delete ignores a missing file but throws for a missing folder (deleted while the app runs): both mean none.
            try { File.Delete(PathFor(slot)); }
            catch (DirectoryNotFoundException) { }
        }
    }

    public IReadOnlyList<string> Slots()
    {
        lock (_gate)
        {
            if (!Directory.Exists(_folder)) return [];
            var slots = new List<string>();
            foreach (var path in Directory.EnumerateFiles(_folder, "*.bin"))
            {
                try
                {
                    if (Read(path) is { } record && string.Equals(Path.GetFileName(path), SecretFile.FileName(record.Slot), StringComparison.OrdinalIgnoreCase)) slots.Add(record.Slot);
                }
                catch (IOException) { } // one unreadable file must not hide the others
                catch (UnauthorizedAccessException) { }
            }
            slots.Sort(StringComparer.Ordinal);
            return slots;
        }
    }

    /// <summary>The slot and secret a file holds; null when it is not this user's (another Windows user or install) or not a secret file.</summary>
    private static (string Slot, string Value)? Read(string path)
    {
        try
        {
            return SecretFile.Decode(ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser));
        }
        catch (CryptographicException)
        {
            // Written by another Windows user or another install: unreadable here, so the phone counts as unpaired.
            return null;
        }
    }

    private string PathFor(string slot) => Path.Combine(_folder, SecretFile.FileName(slot));

    /// <summary>Creates the folder and limits it to the current user: no inherited rules, one full-control rule.</summary>
    private void EnsureFolder()
    {
        var dir = new DirectoryInfo(_folder);
        dir.Create();
        var owner = WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("No current Windows user.");
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            owner, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None, AccessControlType.Allow));
        dir.SetAccessControl(security);
    }
}
