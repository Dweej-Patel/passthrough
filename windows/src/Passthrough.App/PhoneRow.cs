using Microsoft.UI.Xaml;
using Passthrough.Core.Protocol;
using Passthrough.Core.Session;

namespace Passthrough.App;

/// <summary>
/// One phone as the flyout and settings show it. The same row object lives as long as the phone stays attached and
/// is refreshed in place, so a code being typed survives the live status updates.
/// </summary>
public sealed class PhoneRow : ObservableBase
{
    private PhoneEntry _entry;
    private string _code = "";

    public PhoneRow(PhoneEntry entry) => _entry = entry;

    public string Id => _entry.Device.Id;

    public string Marker => _entry.IsActive ? "●" : "○";

    public string Title => _entry.Status?.DeviceName ?? _entry.Device.Label;

    public string StateText => _entry.State switch
    {
        PhoneState.NotPaired => "Not paired",
        PhoneState.Connecting => "Connecting…",
        PhoneState.Paired => "Paired",
        PhoneState.Pairing => "Pairing…",
        PhoneState.Failed => "Failed",
        PhoneState.RemoteOnlyLater => "Not supported yet",
        _ => "",
    };

    /// <summary>"{carrier} · {radio} · {battery}", leaving out what the phone has not said.</summary>
    public string StatusLine
    {
        get
        {
            var s = _entry.Status;
            if (s is null) return "";
            var parts = new List<string>();
            if (!string.IsNullOrEmpty(s.Carrier)) parts.Add(s.Carrier);
            if (!string.IsNullOrEmpty(s.Radio)) parts.Add(s.Radio);
            if (s.Battery is { } battery) parts.Add(battery.ToString("P0"));
            return string.Join(" · ", parts);
        }
    }

    /// <summary>Connections and the bytes carried so far (the phone reports running totals), for the active phone once it is paired.</summary>
    public string ActivityLine
    {
        get
        {
            if (!_entry.IsActive || _entry.State != PhoneState.Paired) return "";
            return $"{_entry.Active} connections · ↓ {Format.Bytes(_entry.Rx)} ↑ {Format.Bytes(_entry.Tx)}";
        }
    }

    public string Message => _entry.Message ?? "";

    public Visibility StatusVisibility => Show(StatusLine.Length > 0);
    public Visibility ActivityVisibility => Show(ActivityLine.Length > 0);
    public Visibility MessageVisibility => Show(Message.Length > 0);

    /// <summary>The six-digit box and Pair button: the active phone, before it is paired.</summary>
    public Visibility PairVisibility => Show(_entry.IsActive && _entry.State is PhoneState.NotPaired or PhoneState.Pairing);

    public bool CanPair => _entry.State == PhoneState.NotPaired;

    /// <summary>[Try again]: the active phone, once its channel failed for good (failed proof, other version, token not saved).</summary>
    public Visibility RetryVisibility => Show(_entry.IsActive && _entry.State == PhoneState.Failed);

    /// <summary>[Use this phone]: any other phone that can be made active.</summary>
    public Visibility UseVisibility => Show(!_entry.IsActive && _entry.State != PhoneState.RemoteOnlyLater);

    /// <summary>Forget pairing, offered whenever this PC holds a token for the phone (even if it is Failed or Connecting).</summary>
    public Visibility ForgetVisibility => Show(_entry.HasPairing);

    public string Code
    {
        get => _code;
        set { _code = value; Raise(nameof(Code)); }
    }

    public void Update(PhoneEntry entry)
    {
        _entry = entry;
        Raise(string.Empty);
    }

    private static Visibility Show(bool on) => on ? Visibility.Visible : Visibility.Collapsed;
}
