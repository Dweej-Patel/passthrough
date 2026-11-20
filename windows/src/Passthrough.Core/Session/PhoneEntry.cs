using Passthrough.Core.Control;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Session;

/// <summary>
/// One attached phone as the UI shows it. <paramref name="Status"/>, <paramref name="Rx"/>, <paramref name="Tx"/> and
/// <paramref name="Active"/> come from the active phone's live status; <paramref name="Message"/> holds pairing-failure
/// or error wording, or null.
/// </summary>
public sealed record PhoneEntry(PhoneDevice Device, PhoneState State, bool IsActive, DeviceStatus? Status, long Rx, long Tx, int Active, string? Message);
