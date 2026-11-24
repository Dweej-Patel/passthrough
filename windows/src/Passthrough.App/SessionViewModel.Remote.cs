using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Passthrough.App.Platform;
using Passthrough.Core.Presentation;
using Passthrough.Windows.Remote;

namespace Passthrough.App;

/// <summary>Someone on this PC now, in the flyout's Remote tab, with Stop.</summary>
public sealed class OnThisPcRow(OnThisPc here)
{
    public string Id { get; } = here.Id;
    public string Title { get; } = here.Name;
    public string Detail { get; } = here.Detail;
    public string Glyph { get; } = here.IsComputer ? Glyphs.Laptop : Glyphs.Phone;
    public string StopName { get; } = $"Stop {here.Name}";
    public string StopTip { get; } = "Ends its shells and any view of the screen now. It keeps its access and can connect again.";
}

/// <summary>Someone viewing this PC's screen, above the tabs: never hidden behind one.</summary>
public sealed class ViewerRow(OnThisPc here)
{
    public string Id { get; } = here.Id;
    public string Text { get; } = here.Syncing ? $"{here.Name} is viewing this screen · syncing the clipboard" : $"{here.Name} is viewing this screen";
    public string StopName { get; } = $"Stop {here.Name}'s view";
}

/// <summary>
/// The flyout's Remote side (stage 8 UX, option B): the header from Remote access, the two tabs, who is on this PC
/// now, anyone viewing the screen, the line that opens Settings, and Stay awake. The words are Core's <see cref="RemoteSummary"/>.
/// </summary>
public sealed partial class SessionViewModel
{
    private const string TabSetting = "flyout.tab";
    private RemoteAccess? _remote;
    private RemoteHeader? _remoteHeader;
    private string _remoteTab = "Remote";
    private string _reachLine = "";
    private bool _stayAwake;
    private bool _stayAwakeKnown;

    public ObservableCollection<OnThisPcRow> OnThisPc { get; } = new();
    public ObservableCollection<ViewerRow> Viewers { get; } = new();

    /// <summary>Follows Remote access from here on (every change arrives on any thread and is applied on the UI thread).</summary>
    public void Attach(RemoteAccess remote)
    {
        _remote = remote;
        void Refresh() => _ui.TryEnqueue(ApplyRemote);
        remote.StatusChanged += Refresh;
        remote.PhonesChanged += Refresh;
        remote.Changed += Refresh;
        remote.Sessions.Changed += Refresh;
        _ui.TryEnqueue(ApplyRemote);
    }

    public bool HasRemote => _remote is not null;
    public Visibility TabsVisibility => _remote is null ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>"This PC" (0) or "Remote" (1), remembered between openings.</summary>
    public int SelectedTab
    {
        get => _settings.Get(TabSetting) == "remote" && _remote is not null ? 1 : 0;
        set
        {
            if (value == SelectedTab) return;
            _settings.Set(TabSetting, value == 1 ? "remote" : "pc");
            Raise(nameof(SelectedTab));
            Raise(nameof(ThisPcVisibility));
            Raise(nameof(RemoteVisibility));
        }
    }

    public Visibility ThisPcVisibility => SelectedTab == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility RemoteVisibility => SelectedTab == 1 ? Visibility.Visible : Visibility.Collapsed;

    public string RemoteTabTitle => _remoteTab;

    private bool _phoneWaits;

    /// <summary>"This PC · Pair" while a phone on the cable waits for its code or a retry.</summary>
    public string ThisPcTabTitle => RemoteSummary.ThisPcTabTitle(_phoneWaits);

    /// <summary>
    /// A phone that starts waiting for its code (or a retry) brings the This PC tab forward, once: the code box is there,
    /// and the header above is Remote access's, so on the Remote tab nothing would say a phone is waiting.
    /// </summary>
    private void ShowWaitingPhone()
    {
        var waits = Rows.Any(r => r.PairVisibility == Visibility.Visible || r.RetryVisibility == Visibility.Visible);
        if (waits == _phoneWaits) return;
        _phoneWaits = waits;
        Raise(nameof(ThisPcTabTitle));
        if (waits && SelectedTab != 0) SelectedTab = 0;
    }

    /// <summary>The header's button (Turn on…, Fix…), which opens Settings ▸ Remote access.</summary>
    public string HeaderActionText => _remoteHeader is null ? "" : RemoteSummary.HeaderAction(Mode) ?? "";
    public Visibility HeaderActionVisibility => HeaderActionText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public string ReachLine => _reachLine;
    public Visibility OnThisPcVisibility => OnThisPc.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility NobodyHereVisibility => OnThisPc.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ViewersVisibility => Viewers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Stay awake while plugged in, on the This PC tab once the service says what it is.</summary>
    public Visibility StayAwakeVisibility => _stayAwakeKnown ? Visibility.Visible : Visibility.Collapsed;
    public bool StayAwake => _stayAwake;

    /// <summary>What Quit asks first; null when quitting ends nothing a phone uses.</summary>
    public string? QuitQuestion => _remote is null ? null : RemoteSummary.QuitQuestion(_remote.Enabled, _remote.Sessions.RunningCount);

    public bool RemoteEnabled => _remote?.Enabled == true;

    private RemoteMode Mode => _remote?.State switch
    {
        null or RemoteAccessState.NeedsSetup => RemoteMode.NeedsSetup,
        RemoteAccessState.Off => RemoteMode.Off,
        RemoteAccessState.Starting => RemoteMode.Starting,
        RemoteAccessState.On => RemoteMode.On,
        _ => RemoteMode.Unavailable,
    };

    private void ApplyRemote()
    {
        if (_remote is not { } remote) return;
        var devices = remote.Phones.Select(p => new RemoteDevice(p.Phone, p.Label, false, p.Connections, p.Viewing, remote.Sessions.RunningSessions(p.Phone)))
            .Concat(remote.Computers.Select(c => new RemoteDevice(c.Id, c.Name, true, c.Connections, c.Viewing, remote.Sessions.RunningSessions(c.Id), remote.IsSyncingClipboard(c.Id))));
        var here = RemoteSummary.Here(devices);
        OnThisPc.Clear();
        foreach (var h in here) OnThisPc.Add(new OnThisPcRow(h));
        Viewers.Clear();
        foreach (var h in here.Where(h => h.Viewing)) Viewers.Add(new ViewerRow(h));
        _remoteHeader = RemoteSummary.Header(Mode, remote.Problem, remote.Phones.Count, here);
        _remoteTab = RemoteSummary.TabTitle(here);
        _reachLine = RemoteSummary.ReachLine(Mode, remote.Phones.Count, remote.Computers.Count);
        foreach (var name in new[]
        {
            nameof(RemoteTabTitle), nameof(ReachLine), nameof(OnThisPcVisibility), nameof(NobodyHereVisibility), nameof(ViewersVisibility),
            nameof(TabsVisibility), nameof(HasRemote), nameof(RemoteEnabled), nameof(SelectedTab), nameof(ThisPcVisibility), nameof(RemoteVisibility),
        }) Raise(name);
        RaiseHeader();
        _ = ShowStayAwakeAsync();
    }

    private async Task ShowStayAwakeAsync()
    {
        try
        {
            var known = false;
            var on = false;
            if (_remote is { State: RemoteAccessState.On } remote && await remote.PowerAsync() is { Error: null } power)
            {
                known = true;
                on = power.StayAwake == true;
            }
            _ui.TryEnqueue(() =>
            {
                if (known == _stayAwakeKnown && on == _stayAwake) return;
                _stayAwakeKnown = known;
                _stayAwake = on;
                Raise(nameof(StayAwakeVisibility));
                Raise(nameof(StayAwake));
            });
        }
        catch (Exception e) { LogFile.Error(e); }
    }

    public async Task SetStayAwakeAsync(bool on)
    {
        if (_remote is null) return;
        await _remote.SetStayAwakeAsync(on);
        await ShowStayAwakeAsync();
    }

    /// <summary>Ends a phone's or computer's shells and any view now; it keeps its access.</summary>
    public Task StopAsync(string id) => _remote?.DisconnectAsync(id) ?? Task.CompletedTask;

    /// <summary>Ends only its view of the screen.</summary>
    public async Task StopViewAsync(string id)
    {
        if (_remote is not null) await _remote.StopScreenAsync(id);
    }

    public Task<string?> TurnOffRemoteAsync() => _remote?.SetEnabledAsync(false) ?? Task.FromResult<string?>(null);

    // MARK: The header: Remote access's once it was set up, the cable's before

    public string HeaderTitle => _remoteHeader?.Title ?? _header.Title;
    public string HeaderSubtitle => _remoteHeader?.Subtitle ?? _header.Subtitle;
    public string HeaderGlyph => _remoteHeader is null ? Glyphs.For(_header.Kind) : Glyphs.Desktop;
    private bool HeaderTinted => _remoteHeader is { } r ? r.Tone == RemoteTone.On : _header.Connected;
    private bool HeaderAttention => _remoteHeader?.Tone == RemoteTone.Attention;
    public Visibility HeaderOnVisibility => HeaderTinted ? Visibility.Visible : Visibility.Collapsed;
    public Visibility HeaderAttentionVisibility => HeaderAttention ? Visibility.Visible : Visibility.Collapsed;
    public Visibility HeaderIdleVisibility => HeaderTinted || HeaderAttention ? Visibility.Collapsed : Visibility.Visible;

    private void RaiseHeader()
    {
        Raise(nameof(HeaderTitle));
        Raise(nameof(HeaderSubtitle));
        Raise(nameof(HeaderGlyph));
        Raise(nameof(HeaderOnVisibility));
        Raise(nameof(HeaderAttentionVisibility));
        Raise(nameof(HeaderIdleVisibility));
        Raise(nameof(HeaderActionText));
        Raise(nameof(HeaderActionVisibility));
    }
}
