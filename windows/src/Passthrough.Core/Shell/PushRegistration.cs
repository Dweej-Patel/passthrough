using System.Text.Json.Serialization;

namespace Passthrough.Core.Shell;

/// <summary>Where and how to send a phone notices (the <c>push</c> request); port of PushNotice.swift.</summary>
public sealed record PushRegistration
{
    public const string Sandbox = "sandbox", Production = "production";

    /// <summary>The device token from APNs, as lowercase hex.</summary>
    [JsonPropertyName("token")] public string Token { get; init; } = "";
    [JsonPropertyName("environment")] public string Environment { get; init; } = "";
    /// <summary>The app's bundle identifier.</summary>
    [JsonPropertyName("topic")] public string Topic { get; init; } = "";
    /// <summary>32 random bytes, base64: what each notice is sealed with.</summary>
    [JsonPropertyName("key")] public string Key { get; init; } = "";
    /// <summary>What the phone calls this host.</summary>
    [JsonPropertyName("mac")] public string Mac { get; init; } = "";

    /// <summary>Never shows the token or the key.</summary>
    public override string ToString() => $"PushRegistration(environment: {Environment}, topic: {Topic}, mac: {Mac})";
}
