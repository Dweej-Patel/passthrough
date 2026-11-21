using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Passthrough.Core.Storage;

/// <summary>
/// How a file-backed <see cref="ISecretStore"/> names and lays out one slot's file. The name is a hash of the slot,
/// so slots that differ only in case (NTFS ignores case) or that are long never share or overflow a path; the slot
/// itself is kept inside the file, so the store can list its slots and check a file belongs to the slot asked for.
/// </summary>
public static class SecretFile
{
    /// <summary>"&lt;64 lowercase hex digits of SHA-256(UTF-8 slot)&gt;.bin".</summary>
    public static string FileName(string slot) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(slot))) + ".bin";

    /// <summary>The plain bytes to protect and store: <c>{"slot":…,"value":…}</c> in UTF-8.</summary>
    public static byte[] Encode(string slot, string value) =>
        JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, string> { ["slot"] = slot, ["value"] = value });

    /// <summary>The slot and value <see cref="Encode"/> wrote, or null for anything else.</summary>
    public static (string Slot, string Value)? Decode(byte[] bytes)
    {
        try
        {
            using var doc = JsonDocument.Parse(bytes);
            var root = doc.RootElement;
            if (root.ValueKind == JsonValueKind.Object
                && root.TryGetProperty("slot", out var slot) && slot.ValueKind == JsonValueKind.String
                && root.TryGetProperty("value", out var value) && value.ValueKind == JsonValueKind.String)
                return (slot.GetString()!, value.GetString()!);
        }
        catch (JsonException) { }
        return null;
    }
}
