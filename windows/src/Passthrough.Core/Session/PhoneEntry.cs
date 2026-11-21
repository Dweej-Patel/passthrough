using Passthrough.Core.Control;
using Passthrough.Core.Transport;

namespace Passthrough.Core.Session;

/// <summary>
/// One attached phone as the UI shows it. <paramref name="Status"/>, <paramref name="Rx"/>, <paramref name="Tx"/> and
/// <paramref name="Active"/> come from the active phone's live status; <paramref name="Message"/> holds pairing-failure
/// or error wording, or null. <paramref name="HasPairing"/> is true when this PC holds a token for the phone, whatever its state.
/// <paramref name="Attachment"/> numbers this attachment of the phone (a phone unplugged and plugged back in gets a new
/// one); a code is addressed to a phone by its id and this number (see <see cref="HostSession.SubmitCodeAsync"/>).
/// <paramref name="SavedName"/> is the name the phone last gave itself while paired with this PC (kept beside its
/// pairing), or null; it names a phone whose live status is not known.
/// </summary>
public sealed record PhoneEntry(PhoneDevice Device, PhoneState State, bool IsActive, DeviceStatus? Status, long Rx, long Tx, int Active, string? Message, bool HasPairing, long Attachment, string? SavedName = null);
