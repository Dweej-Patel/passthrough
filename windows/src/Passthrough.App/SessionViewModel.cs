using System.Collections.ObjectModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Passthrough.App.Platform;
using Passthrough.Core.Presentation;
using Passthrough.Core.Session;
using Passthrough.Core.Storage;

namespace Passthrough.App;

/// <summary>
/// What the windows bind to. <see cref="HostSession.StateChanged"/> arrives on the session's own thread, so each
/// state is handed to the UI thread and applied there; the handler never waits on the session. The rules (rows,
/// hints, stored pairings) are Core's <see cref="PhoneRowModel"/>, <see cref="RowList"/>, <see cref="WatcherHints"/>
/// and <see cref="PairedPhone"/>.
/// </summary>
public sealed class SessionViewModel : ObservableBase
{
    private readonly HostSession _session;
    private readonly ISettingsStore _settings;
    private readonly DispatcherQueue _ui;
    private readonly string? _notice;
    private string _hints = "";
    private string _pairingsKey = "";
    private bool _androidEnabled;
    private SessionState _state;
    /// <summary>The slots this PC holds a pairing in, attached or not, as last read; they decide which install hints show.</summary>
    private IReadOnlyList<string> _pairedSlots = [];

    /// <param name="notice">A line to show above the watcher hints for the whole run (the settings file was damaged), or null.</param>
    public SessionViewModel(HostSession session, ISettingsStore settings, DispatcherQueue ui, bool androidEnabled, string? notice)
    {
        _session = session;
        _settings = settings;
        _ui = ui;
        _androidEnabled = androidEnabled;
        _notice = notice;
        _state = _session.State;
        _session.StateChanged += state => _ui.TryEnqueue(() => Apply(state));
        Apply(_session.State);
        RefreshPairedSlots();
    }

    public ObservableCollection<PhoneRow> Rows { get; } = new();

    /// <summary>Raised on the UI thread when an attached phone's pairing or saved name changed, so Settings can list the stored pairings again.</summary>
    public event Action? PairingsChanged;

    public bool AndroidEnabled
    {
        get => _androidEnabled;
        private set { _androidEnabled = value; Raise(nameof(AndroidEnabled)); }
    }

    public Visibility EmptyVisibility => Rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>What the user should do (install or open Apple Devices, allow USB debugging…), one per line.</summary>
    public string Hints
    {
        get => _hints;
        private set { _hints = value; Raise(nameof(Hints)); Raise(nameof(HintsVisibility)); }
    }

    public Visibility HintsVisibility => _hints.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

    public Task UseAsync(string phoneId) => _session.MakeActiveAsync(phoneId);

    public Task RetryAsync(string phoneId) => _session.RetryAsync(phoneId);

    /// <summary>Sends a code to the phone of the row it was typed into; false when it was not sent (the phone changed meanwhile).</summary>
    public Task<bool> SubmitCodeAsync(PhoneRow row, string code) => _session.SubmitCodeAsync(row.Id, row.Attachment, code);

    /// <summary>Every pairing this PC holds, attached or not, named for Settings.</summary>
    public async Task<IReadOnlyList<PairedPhone>> PairedPhonesAsync() =>
        PairedPhone.List(await _session.PairedSlotsAsync(), slot => DeviceNames.Get(_settings, slot));

    public async Task ForgetSlotAsync(string slot)
    {
        await _session.ForgetSlotAsync(slot);
        RefreshPairedSlots(); // the phone may not be attached, so no state change would say so
    }

    /// <summary>Changes the setting; <see cref="AndroidEnabled"/> follows only once the session has accepted it.</summary>
    public async Task SetAndroidEnabledAsync(bool on)
    {
        await _session.SetAndroidEnabledAsync(on);
        AndroidEnabled = on;
    }

    private void Apply(SessionState state)
    {
        _state = state;
        RowList.Reconcile(Rows, state.Phones, r => r.Id, e => new PhoneRow(e), (r, e) => r.Update(e));
        Raise(nameof(EmptyVisibility));
        ShowHints();

        var key = string.Join("\n", state.Phones.Select(p => $"{p.Device.PairingSlot}|{p.HasPairing}|{p.SavedName}"));
        if (key == _pairingsKey) return;
        _pairingsKey = key;
        PairingsChanged?.Invoke();
        RefreshPairedSlots();
    }

    private void ShowHints()
    {
        var hints = new List<string>();
        if (_notice is not null) hints.Add(_notice);
        hints.AddRange(WatcherHints.For(_state, _pairedSlots));
        Hints = string.Join(Environment.NewLine, hints);
    }

    /// <summary>Reads the stored pairings again (on the UI thread once read) and redoes the hints.</summary>
    private async void RefreshPairedSlots()
    {
        try
        {
            _pairedSlots = await _session.PairedSlotsAsync();
            ShowHints();
        }
        catch (Exception e)
        {
            LogFile.Error(e);
        }
    }
}
