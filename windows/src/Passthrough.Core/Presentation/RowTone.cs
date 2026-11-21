namespace Passthrough.Core.Presentation;

/// <summary>What a phone's state means at a glance; the flyout colours the row's dot by it.</summary>
public enum RowTone
{
    /// <summary>Nothing to say: another phone waiting its turn, an iPad, a channel being opened.</summary>
    Neutral,

    /// <summary>Paired and working.</summary>
    Good,

    /// <summary>A person is needed: the active phone waits for its code.</summary>
    Attention,

    /// <summary>The channel failed for good.</summary>
    Problem,
}
