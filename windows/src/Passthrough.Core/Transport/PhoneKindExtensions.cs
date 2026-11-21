namespace Passthrough.Core.Transport;

/// <summary>Display names for <see cref="PhoneKind"/>.</summary>
public static class PhoneKindExtensions
{
    /// <summary>"iPhone", "Android phone" or "iPad", for UI copy.</summary>
    public static string Label(this PhoneKind kind) => kind switch
    {
        PhoneKind.IPhone => "iPhone",
        PhoneKind.Android => "Android phone",
        PhoneKind.IPad => "iPad",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };
}
