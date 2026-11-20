namespace Passthrough.Core.Storage;

/// <summary>Where pairing tokens live, one per slot (<c>token.iphone.&lt;UDID&gt;</c>, <c>token.ipad.&lt;UDID&gt;</c>, <c>token.android.&lt;serial&gt;</c>).</summary>
public interface ISecretStore
{
    /// <summary>The secret in <paramref name="slot"/>, or null when there is none.</summary>
    string? Get(string slot);

    void Set(string slot, string value);

    /// <summary>Removes the secret; does nothing when there is none.</summary>
    void Delete(string slot);
}
