using System.Security.AccessControl;
using System.Security.Principal;

namespace Passthrough.Windows.Remote;

/// <summary>
/// A folder only this Windows account (and the system) can open, whatever it inherited: what sessions' transcripts
/// are kept in, since what a script printed (secrets included) is in them. The Mac makes its folder 0700.
/// </summary>
public static class PrivateFolder
{
    public static void Restrict(string path, Action<string>? log = null)
    {
        try
        {
            var folder = Directory.CreateDirectory(path);
            using var me = WindowsIdentity.GetCurrent();
            if (me.User is not { } user) return;
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            security.SetOwner(user);
            const InheritanceFlags both = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, both, PropagationFlags.None, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                FileSystemRights.FullControl, both, PropagationFlags.None, AccessControlType.Allow));
            folder.SetAccessControl(security);
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or InvalidOperationException or PrivilegeNotHeldException)
        {
            // Still in the profile, which other accounts can't open: say so, don't fail.
            log?.Invoke($"shell: couldn't restrict the history folder ({e.GetType().Name})");
        }
    }

    /// <summary>Whether anyone besides this account and the system is allowed in (tests).</summary>
    internal static bool OnlyMine(string path)
    {
        using var me = WindowsIdentity.GetCurrent();
        var rules = new DirectoryInfo(path).GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier));
        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        return rules.Cast<FileSystemAccessRule>().All(r => r.IdentityReference.Equals(me.User) || r.IdentityReference.Equals(system));
    }
}
