using Passthrough.Core.Protocol;

namespace Passthrough.Core.Control;

/// <summary>What a <see cref="ControlClient"/> reports. <see cref="Disconnected"/> is always the last event.</summary>
public abstract record ControlEvent
{
    private ControlEvent() { }

    /// <summary>
    /// The phone answered <c>hello</c>. <paramref name="Paired"/>: the phone proved it holds this PC's pairing
    /// and the PC proved it back. False: pair first. Name and status follow as <see cref="StatusUpdate"/>.
    /// </summary>
    public sealed record Welcomed(bool Paired) : ControlEvent;

    /// <summary>A code pairing this PC asked for worked; store <paramref name="Token"/> for the phone. Never printed.</summary>
    public sealed record PairedWith(string Token) : ControlEvent
    {
        public override string ToString() => "PairedWith { Token = (redacted) }";
    }

    public sealed record PairingFailed(PairingFailure Reason) : ControlEvent;

    /// <summary>The phone's live status (authenticated channels only).</summary>
    public sealed record StatusUpdate(DeviceStatus Status, long Rx, long Tx, int Active) : ControlEvent;

    /// <summary>The phone's user turned Passthrough off; the phone stops right after.</summary>
    public sealed record Goodbye : ControlEvent;

    /// <summary>The channel closed: null for the phone closing it cleanly, else why.</summary>
    public sealed record Disconnected(Exception? Error) : ControlEvent;
}
