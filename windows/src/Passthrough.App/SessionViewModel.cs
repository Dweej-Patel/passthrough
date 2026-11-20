using System.Collections.ObjectModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Passthrough.Core.Session;
using Passthrough.Core.Transport;

namespace Passthrough.App;

/// <summary>
/// What the windows bind to. <see cref="HostSession.StateChanged"/> arrives on the session's own thread, so each
/// state is handed to the UI thread and applied there; the handler never waits on the session.
/// </summary>
public sealed class SessionViewModel : ObservableBase
{
    private readonly HostSession _session;
    private readonly DispatcherQueue _ui;
    private string _hints = "";
    private bool _androidEnabled;

    public SessionViewModel(HostSession session, DispatcherQueue ui, bool androidEnabled)
    {
        _session = session;
        _ui = ui;
        _androidEnabled = androidEnabled;
        _session.StateChanged += state => _ui.TryEnqueue(() => Apply(state));
        Apply(_session.State);
    }

    public ObservableCollection<PhoneRow> Rows { get; } = new();

    public bool AndroidEnabled
    {
        get => _androidEnabled;
        private set { _androidEnabled = value; Raise(nameof(AndroidEnabled)); }
    }

    public Visibility EmptyVisibility => Rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>What each watcher needs from the user (install Apple Devices, allow USB debugging), one per line.</summary>
    public string Hints
    {
        get => _hints;
        private set { _hints = value; Raise(nameof(Hints)); Raise(nameof(HintsVisibility)); }
    }

    public Visibility HintsVisibility => _hints.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

    public Task UseAsync(string phoneId) => _session.MakeActiveAsync(phoneId);

    public Task RetryAsync(string phoneId) => _session.RetryAsync(phoneId);

    public Task SubmitCodeAsync(string code) => _session.SubmitCodeAsync(code);

    public Task ForgetAsync(string phoneId) => _session.ForgetAsync(phoneId);

    /// <summary>Changes the setting; <see cref="AndroidEnabled"/> follows only once the session has accepted it.</summary>
    public async Task SetAndroidEnabledAsync(bool on)
    {
        await _session.SetAndroidEnabledAsync(on);
        AndroidEnabled = on;
    }

    private void Apply(SessionState state)
    {
        var existing = Rows.ToDictionary(r => r.Id);
        var next = new List<PhoneRow>();
        foreach (var entry in state.Phones)
        {
            if (existing.TryGetValue(entry.Device.Id, out var row)) row.Update(entry);
            else row = new PhoneRow(entry);
            next.Add(row);
        }

        // Add, remove and reorder only when the set of phones changed, so rows being edited are left alone.
        if (!next.SequenceEqual(Rows))
        {
            Rows.Clear();
            foreach (var row in next) Rows.Add(row);
        }
        Raise(nameof(EmptyVisibility));

        var hints = new List<string>();
        AddHint(hints, "Apple Devices", state.UsbMux);
        AddHint(hints, "adb", state.Adb);
        Hints = string.Join(Environment.NewLine, hints);
    }

    private static void AddHint(List<string> hints, string name, WatchStatus status)
    {
        if (!string.IsNullOrEmpty(status.Hint)) hints.Add(status.Hint);
        else if (status.State == WatchState.NotInstalled) hints.Add($"{name} was not found.");
    }
}
