using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Passthrough.Core.Storage;

namespace Passthrough.App.Storage;

/// <summary>
/// One DPAPI-protected file per slot (<c>&lt;folder&gt;\&lt;slot&gt;.bin</c>), readable only by the current Windows user.
/// Slot names are already file-safe (letters, digits, <c>-</c>, <c>_</c>, <c>.</c>).
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
            try
            {
                var plain = ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(plain);
            }
            catch (CryptographicException)
            {
                // Written by another Windows user or another install: unreadable here, so the phone counts as unpaired.
                return null;
            }
        }
    }

    public void Set(string slot, string value)
    {
        lock (_gate)
        {
            EnsureFolder();
            var path = PathFor(slot);
            var temp = path + ".tmp";
            File.WriteAllBytes(temp, ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
            File.Move(temp, path, overwrite: true);
        }
    }

    public void Delete(string slot)
    {
        lock (_gate)
        {
            File.Delete(PathFor(slot)); // does nothing when the file is absent
        }
    }

    private string PathFor(string slot) => Path.Combine(_folder, slot + ".bin");

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
