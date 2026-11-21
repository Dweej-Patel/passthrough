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
    private FlyoutHeader _header;
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
        _header = FlyoutHeader.For(_state);
        _session.StateChanged += state => _ui.TryEnqueue(() => Apply(state));
        Apply(_session.State);
        RefreshPairedSlots();
    }

    public ObservableCollection<PhoneRow> Rows { get; } = new();

    /// <summary>Remote access's notices (the screen was used, a phone was given access…), each until answered.</summary>
    public ObservableCollection<NoticeRow> Notices { get; } = new();

    /// <summary>The other computers this PC can reach, once opened with Windows Hello.</summary>
    public ObservableCollection<ComputerRow> Computers { get; } = new();

    private bool _computersShown;

    /// <summary>"Your computers" shows a Show button until the list has been opened (one Hello confirmation).</summary>
    public Visibility ShowComputersVisibility => _computersShown ? Visibility.Collapsed : Visibility.Visible;
    public Visibility ComputersVisibility => _computersShown && Computers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Opens the kept computers (Windows Hello); null when none can be kept here.</summary>
    public Func<Task<IReadOnlyList<Passthrough.Core.Trust.ReachableComputer>?>>? OpenComputers { get; set; }

    /// <summary>A new shell on a computer, in a terminal.</summary>
    public Func<Passthrough.Core.Trust.ReachableComputer, Task>? NewShell { get; set; }

    public async Task ShowComputersAsync()
    {
        if (OpenComputers is not { } open || await open() is not { } list) return;
        _computersShown = true;
        Computers.Clear();
        foreach (var c in list) Computers.Add(new ComputerRow(c));
        Raise(nameof(ShowComputersVisibility));
        Raise(nameof(ComputersVisibility));
    }

    /// <summary>Answers a notice (OK, or its action first).</summary>
    public Func<Passthrough.Core.Pipe.PipeNotice, bool, Task>? AnswerNotice { get; set; }

    /// <summary>Replaces the notices (on the UI thread).</summary>
    public void ShowNotices(IReadOnlyList<Passthrough.Core.Pipe.PipeNotice> notices) => _ui.TryEnqueue(() =>
    {
        Notices.Clear();
        foreach (var notice in notices) Notices.Add(new NoticeRow(notice));
    });

    /// <summary>Raised on the UI thread when an attached phone's pairing or saved name changed, so Settings can list the stored pairings again.</summary>
    public event Action? PairingsChanged;

    public bool AndroidEnabled
    {
        get => _androidEnabled;
        private set { _androidEnabled = value; Raise(nameof(AndroidEnabled)); }
    }

    /// <summary>The two lines at the top of the flyout and their picture, by Core's <see cref="FlyoutHeader"/>.</summary>
    public string HeaderTitle => _header.Title;
    public string HeaderSubtitle => _header.Subtitle;
    public string HeaderGlyph => Glyphs.For(_header.Kind);
    public Visibility HeaderOnVisibility => _header.Connected ? Visibility.Visible : Visibility.Collapsed;
    public Visibility HeaderIdleVisibility => _header.Connected ? Visibility.Collapsed : Visibility.Visible;

    public Visibility RowsVisibility => Rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;

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
        Raise(nameof(RowsVisibility));
        var header = FlyoutHeader.For(state);
        if (header != _header)
        {
            _header = header;
            Raise(nameof(HeaderTitle));
            Raise(nameof(HeaderSubtitle));
            Raise(nameof(HeaderGlyph));
            Raise(nameof(HeaderOnVisibility));
            Raise(nameof(HeaderIdleVisibility));
        }
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
