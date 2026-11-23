using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Passthrough.Core.Desktop;
using Windows.Graphics;
using Passthrough.App.Platform;
using Passthrough.Core.Presentation;
using Passthrough.Windows.Remote;

namespace Passthrough.App;

/// <summary>Android support, start at login, Remote access and the phones it lets in, and forgetting any stored pairing.</summary>
public sealed partial class SettingsWindow : Window
{
    private const int WidthDip = 640;
    private const int HeightDip = 760;

    private bool _forgetting;
    private bool _revoking;
    private readonly RemoteAccess? _remote;
    private readonly bool _isAdministrator = Passthrough.Windows.Shell.UserEnvironment.IsAdministratorAccount();

    public SettingsWindow(SessionViewModel viewModel, RemoteAccess? remote = null)
    {
        ViewModel = viewModel;
        _remote = remote;
        InitializeComponent();
        AppWindow.SetIcon(AppIcon.Path); // the taskbar button and Alt+Tab; without it Windows shows a blank default
        SystemBackdrop = new MicaBackdrop();
        // The Mica runs under the caption buttons too; the strip above the scrolling content is what drags the window.
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarArea);
        var hwnd = Win32Interop.GetWindowFromWindowId(AppWindow.Id);
        var scale = FlyoutPlacement.ScaleFromDpi(NativeMethods.DpiOf(hwnd));
        AppWindow.Resize(new SizeInt32((int)Math.Round(WidthDip * scale), (int)Math.Round(HeightDip * scale)));

        // Set the switches before listening, so loading the saved values does not count as a change.
        AndroidSwitch.IsOn = viewModel.AndroidEnabled;
        StartAtLoginSwitch.IsOn = ReadStartAtLogin();
        AndroidSwitch.Toggled += OnAndroidToggled;
        StartAtLoginSwitch.Toggled += OnStartAtLoginToggled;
        RemoteSwitch.IsOn = remote?.Enabled ?? false;
        RemoteSwitch.IsEnabled = remote is not null;
        RemoteSwitch.Toggled += OnRemoteToggled;
        if (remote is not null)
        {
            // Fired on any thread; shown on this one.
            void Refresh() => DispatcherQueue.TryEnqueue(ShowRemote);
            remote.StatusChanged += Refresh;
            remote.PhonesChanged += Refresh;
            remote.Sessions.Changed += Refresh;
            Closed += (_, _) =>
            {
                remote.StatusChanged -= Refresh;
                remote.PhonesChanged -= Refresh;
                remote.Sessions.Changed -= Refresh;
            };
        }
        ShowRemote();
        // The history choice and the relay's sentence too: they were filled only after a change, so they opened blank.
        ShowHistoryAndRelay();

        ShowPage(GeneralPage);
        // The setting and the pairings can change while the window is open; follow them until it closes.
        viewModel.PropertyChanged += OnViewModelChanged;
        viewModel.PairingsChanged += OnPairingsChanged;
        Closed += (_, _) =>
        {
            viewModel.PropertyChanged -= OnViewModelChanged;
            viewModel.PairingsChanged -= OnPairingsChanged;
        };
        OnPairingsChanged();
    }

    public SessionViewModel ViewModel { get; }

    /// <summary>One row per phone: its pairing, its access here, or both.</summary>
    public ObservableCollection<PhoneSettingsRow> Phones { get; } = new();
    public ObservableCollection<ComputerAccessRow> ComputersWithAccess { get; } = new();

    /// <summary>The stored pairings, as Core's <see cref="PairedPhone.List"/> names them, as last read.</summary>
    private IReadOnlyList<PairedPhone> _paired = [];

    public const string GeneralPage = "general", RemotePage = "remote", ComputersPage = "computers", AdvancedPage = "advanced";

    /// <summary>Shows one page: General, Remote access, Your computers or Advanced.</summary>
    public void ShowPage(string page)
    {
        foreach (var item in Pages.MenuItems.OfType<NavigationViewItem>())
            if ((string)item.Tag == page) Pages.SelectedItem = item;
    }

    private void OnPageChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var page = (args.SelectedItem as NavigationViewItem)?.Tag as string ?? GeneralPage;
        GeneralPanel.Visibility = page == GeneralPage ? Visibility.Visible : Visibility.Collapsed;
        RemotePanel.Visibility = page == RemotePage ? Visibility.Visible : Visibility.Collapsed;
        ComputersPanel.Visibility = page == ComputersPage ? Visibility.Visible : Visibility.Collapsed;
        AdvancedPanel.Visibility = page == AdvancedPage ? Visibility.Visible : Visibility.Collapsed;
    }


    /// <summary>The pairings and the access records, joined by pairing slot into one row per phone.</summary>
    private void RebuildPhones()
    {
        var access = _remote?.Phones ?? [];
        var connected = _remote?.ConnectedPhones.ToHashSet() ?? [];
        int Sessions(string id) => _remote?.Sessions.RunningSessions(id) ?? 0;
        Phones.Clear();
        var joined = new HashSet<string>();
        foreach (var paired in _paired)
        {
            var device = access.FirstOrDefault(a => a.PairingSlot == paired.Slot);
            if (device is not null) joined.Add(device.Phone);
            Phones.Add(new PhoneSettingsRow(paired, device, device is not null && connected.Contains(device.Phone), device is null ? 0 : Sessions(device.Phone), _screenReady));
        }
        // Every access record has a row: one without a pairing, or a second id through the same pairing (a reinstalled app).
        foreach (var device in access.Where(a => !joined.Contains(a.Phone)))
            Phones.Add(new PhoneSettingsRow(_paired.FirstOrDefault(p => p.Slot == device.PairingSlot), device, connected.Contains(device.Phone), Sessions(device.Phone), _screenReady));
        NoPhonesText.Visibility = Phones.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Whether Start at login is on; a registry that can't be read shows it off, with the error line, instead of failing the window.</summary>
    private bool ReadStartAtLogin()
    {
        try { return StartupRegistration.IsEnabled(); }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Couldn't read the Start at login setting. See the log for details.");
            return false;
        }
    }

    /// <summary>Raised on the UI thread (the view model is only changed there).</summary>
    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is not (nameof(SessionViewModel.AndroidEnabled) or "" or null)) return;
        ShowAndroidEnabled();
    }

    /// <summary>Lists the stored pairings again (on opening, after a Forget, and when a phone's pairing changed).</summary>
    private async void OnPairingsChanged()
    {
        try
        {
            _paired = await ViewModel.PairedPhonesAsync();
            RebuildPhones();
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Couldn't list the paired phones. See the log for details.");
        }
    }

    /// <summary>Shows the setting as it really is, without running the toggle handler.</summary>
    private void ShowAndroidEnabled()
    {
        if (AndroidSwitch.IsOn == ViewModel.AndroidEnabled) return;
        AndroidSwitch.Toggled -= OnAndroidToggled;
        AndroidSwitch.IsOn = ViewModel.AndroidEnabled;
        AndroidSwitch.Toggled += OnAndroidToggled;
    }

    private async void OnAndroidToggled(object sender, RoutedEventArgs e)
    {
        var wanted = AndroidSwitch.IsOn;
        try
        {
            await ViewModel.SetAndroidEnabledAsync(wanted);
            ErrorBox.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowAndroidEnabled();
            ShowError("Could not change Android support. See the log for details.");
        }
    }

    private void OnStartAtLoginToggled(object sender, RoutedEventArgs e)
    {
        try
        {
            StartupRegistration.SetEnabled(StartAtLoginSwitch.IsOn);
            ErrorBox.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            StartAtLoginSwitch.Toggled -= OnStartAtLoginToggled;
            StartAtLoginSwitch.IsOn = ReadStartAtLogin();
            StartAtLoginSwitch.Toggled += OnStartAtLoginToggled;
            ShowError("Could not change Start at login. See the log for details.");
        }
    }

    private async void OnForgetClick(object sender, RoutedEventArgs e)
    {
        // One dialog at a time: a second click while it is up would make ShowAsync throw.
        if (_forgetting) return;
        _forgetting = true;
        var phone = (PhoneSettingsRow)((FrameworkElement)sender).DataContext;
        if (phone.Slot is null) { _forgetting = false; return; }
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = $"Forget {phone.Title}?",
                Content = phone.HasAccess
                    ? "This PC forgets its pairing, and it loses its access here: its shells and any view of the screen end. Pair again with the code the phone shows, then plug it in with Remote access on."
                    : "This PC will no longer be paired with it. You can pair again with the code the phone shows.",
                PrimaryButtonText = "Forget",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                await ViewModel.ForgetSlotAsync(phone.Slot);
                ErrorBox.Visibility = Visibility.Collapsed;
            }
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not forget the pairing. See the log for details.");
        }
        finally
        {
            _forgetting = false;
        }
        OnPairingsChanged();
    }

    /// <summary>The switch's state, its line, the shells offered and the phones let in, as they are now.</summary>
    private void ShowRemote()
    {
        if (_remote is null)
        {
            RemoteStatusText.Text = "Not available in this copy of Passthrough.";
            return;
        }
        RemoteStatusText.Text = _remote.State switch
        {
            RemoteAccessState.NeedsSetup when _remote.NeedsFinishing =>
                "Remote access needs one more step. It now runs as a background service, so this PC answers before you sign in. Windows will ask for an administrator once. Afterwards, plug each phone in once.",
            RemoteAccessState.NeedsSetup => "Off. Turning it on sets up a background service, so this PC answers before you sign in. Windows will ask for an administrator once.",
            RemoteAccessState.Off => "Off. Phones can't reach this PC's shell. Turning it on asks Windows for an administrator.",
            RemoteAccessState.Starting => "Starting…",
            RemoteAccessState.On when _remote.HomeRelay is { } relay =>
                $"On. Phones you've plugged in once reach this PC from anywhere, directly or through {RelayName(relay)}. Shells work while you're signed in and Passthrough is open.",
            RemoteAccessState.On => "On. Phones you've plugged in once reach this PC directly; looking for a relay for when they're away. Shells work while you're signed in and Passthrough is open.",
            _ => _remote.Problem ?? "Remote access couldn't start. See the log for details.",
        };
        if (RemoteSwitch.IsOn != _remote.Enabled)
        {
            RemoteSwitch.Toggled -= OnRemoteToggled;
            RemoteSwitch.IsOn = _remote.Enabled;
            RemoteSwitch.Toggled += OnRemoteToggled;
        }
        _ = ShowAwakeAsync();
        _ = ShowScreenAsync();
        var shells = _remote.Catalog.Shells.Select(s => s.Name).ToList();
        ShellsText.Text = (shells.Count == 0 ? "" : $"Shells: {string.Join(", ", shells)}. They open as you, never as administrator.")
            + (_isAdministrator ? " Your Windows account is an administrator, so a phone with access can do anything you can, including approving administrator prompts." : "");
        // One prompt sets up the shell and the screen together, the first time.
        ScreenWithTurnOn.Visibility = RemoteAccess.IsInstalled ? Visibility.Collapsed : Visibility.Visible;
        RebuildPhones();
        ComputersWithAccess.Clear();
        foreach (var computer in _remote.Computers) ComputersWithAccess.Add(new ComputerAccessRow(computer));
        NoComputersText.Visibility = ComputersWithAccess.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private bool _settingAwake;
    private bool _screenReady;
    private string? _screenAction;

    /// <summary>The Screen row: what the service says this PC's Remote Desktop can do for this account, and the one fix.</summary>
    private async Task ShowScreenAsync()
    {
        if (_remote?.State != RemoteAccessState.On || await _remote.ScreenRowAsync() is not { } row)
        {
            ScreenText.Text = "Turn Remote access on first.";
            ScreenButton.Visibility = Visibility.Collapsed;
            return;
        }
        var ready = row.Rdp == "ready";
        if (ready != _screenReady)
        {
            _screenReady = ready;
            ShowRemote();
        }
        ScreenText.Text = row.Reason is { } reason ? $"{row.Text} {reason}" : row.Text;
        // Each fix is one administrator prompt.
        _screenAction = row.Action switch
        {
            "Set up…" => "screen",
            "Close it" or "Close it to the network" => "screen-close",
            "Turn on" or "Require it" or "Try again" => "screen",
            _ => null,
        };
        ScreenButton.Content = row.Action;
        ScreenButton.Visibility = _screenAction is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void OnScreenActionClick(object sender, RoutedEventArgs e)
    {
        if (_remote is null || _screenAction is null) return;
        try
        {
            if (await _remote.ConfigureScreenAsync(_screenAction) is { } said) ShowError(said);
            else ErrorBox.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not set up the screen. See the log for details.");
        }
        await ShowScreenAsync();
    }

    private async void OnScreenClick(object sender, RoutedEventArgs e)
    {
        if (_remote is null) return;
        var box = (CheckBox)sender;
        if (box.DataContext is not PhoneSettingsRow { PhoneId: { } phoneId }) return;
        try { await _remote.SetScreenAllowedAsync(phoneId, box.IsChecked == true); }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not change what it may see. See the log for details.");
        }
        ShowRemote();
    }

    private async void OnComputerScreenClick(object sender, RoutedEventArgs e)
    {
        if (_remote is null) return;
        var computer = (ComputerAccessRow)((FrameworkElement)sender).DataContext;
        // Allow screen while it waits; Turn off screen once it may see it.
        try { await _remote.SetComputerScreenAsync(computer.Id, !computer.AllowedHere); }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not change what that computer may see. See the log for details.");
        }
        ShowRemote();
    }

    private async void OnComputerRevokeClick(object sender, RoutedEventArgs e)
    {
        if (_remote is null) return;
        var computer = (ComputerAccessRow)((FrameworkElement)sender).DataContext;
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = $"Revoke {computer.Title}?",
            Content = "Its shells and any view of the screen close, and it loses access to this PC. A phone can share it again.",
            PrimaryButtonText = "Revoke",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try { await _remote.RevokeComputerAsync(computer.Id); }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not revoke that computer. See the log for details.");
        }
        ShowRemote();
    }

    private async void OnShareClick(object sender, RoutedEventArgs e)
    {
        if (_remote is null) return;
        var box = (CheckBox)sender;
        if (box.DataContext is not PhoneSettingsRow { PhoneId: { } phoneId }) return;
        try { await _remote.SetMayShareAsync(phoneId, box.IsChecked == true); }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not change whether it may share access. See the log for details.");
        }
        ShowRemote();
    }

    /// <summary>Staying reachable: the service's power facts, and the switch (no prompt: any allowed account may change it).</summary>
    private async Task ShowAwakeAsync()
    {
        if (_remote?.State != RemoteAccessState.On || await _remote.PowerAsync() is not { Error: null } power)
        {
            AwakeCard.Visibility = Visibility.Collapsed;
            return;
        }
        AwakeCard.Visibility = Visibility.Visible;
        var minutes = (power.SleepAfter ?? 0) / 60;
        AwakeText.Text = power.StayAwake == true
            ? power.OnMains == true ? "Stays awake on mains power." : $"On battery this PC sleeps after {minutes} minutes."
            : minutes > 0 ? $"This PC sleeps after {minutes} minutes. A sleeping PC can't answer." : "This PC doesn't sleep by itself.";
        _settingAwake = true;
        AwakeSwitch.IsOn = power.StayAwake == true;
        _settingAwake = false;
    }

    private async void OnAwakeToggled(object sender, RoutedEventArgs e)
    {
        if (_settingAwake || _remote is null) return;
        try
        {
            if ((await _remote.SetStayAwakeAsync(AwakeSwitch.IsOn)).Error is { } error) ShowError($"Could not change Stay awake ({error}).");
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not change Stay awake. See the log for details.");
        }
        await ShowAwakeAsync();
    }

    private static readonly (int Days, string Name)[] HistoryNames = [(7, "1 week"), (30, "30 days"), (365, "1 year"), (0, "Forever")];

    private void ShowHistoryAndRelay()
    {
        var enabled = _remote is not null;
        HistoryChoice.IsEnabled = DeleteHistoryButton.IsEnabled = RelayUrlBox.IsEnabled = RelayTokenBox.IsEnabled = enabled;
        if (_remote is null) return;
        HistoryChoice.SelectionChanged -= OnHistoryChanged;
        HistoryChoice.Items.Clear();
        foreach (var (_, name) in HistoryNames) HistoryChoice.Items.Add(name);
        HistoryChoice.SelectedIndex = Array.FindIndex(HistoryNames, h => h.Days == _remote.HistoryDays);
        HistoryChoice.SelectionChanged += OnHistoryChanged;
        RelayUrlBox.Text = _remote.RelayUrl ?? "";
        RelayTokenBox.Password = "";
        RelayText.Text = _remote.RelayUrl is { } url
            ? $"Phones away from this network reach this PC through {RelayName(url)}{(_remote.HasRelayToken ? ", with its token" : "")}."
            : "Phones away from this network reach this PC through the public relays run by n0, iroh's makers. They carry only encrypted traffic.";
    }

    private void OnHistoryChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_remote is null || HistoryChoice.SelectedIndex < 0) return;
        _remote.HistoryDays = HistoryNames[HistoryChoice.SelectedIndex].Days;
    }

    private async void OnDeleteHistoryClick(object sender, RoutedEventArgs e)
    {
        if (_remote is null) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Delete shell history?",
            Content = "Every finished session's history on this PC is deleted. Shells still running keep theirs.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) _remote.DeleteHistory();
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not delete the shell history. See the log for details.");
        }
    }

    private async void OnRelayClick(object sender, RoutedEventArgs e)
    {
        if (_remote is null) return;
        var url = RelayUrlBox.Text.Trim();
        if (url.Length > 0 && RemoteAccess.ValidRelayUrl(url) is null)
        {
            ShowError("A relay's address starts with https:// and has nothing after its path.");
            return;
        }
        try
        {
            // An empty token box keeps the token kept for this relay; n0's relays take none. Installed, it asks for an administrator.
            if (await _remote.SetRelayAsync(url.Length == 0 ? null : url, RelayTokenBox.Password.Length == 0 ? null : RelayTokenBox.Password) is { } said) ShowError(said);
            else ErrorBox.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not change the relay. See the log for details.");
        }
        ShowHistoryAndRelay();
        ShowRemote();
    }

    private async void OnResetIdentityClick(object sender, RoutedEventArgs e)
    {
        if (_remote is null) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Reset this PC's identity?",
            Content = "This PC gets a new address for phones. Every phone loses its access, and its shells here end. Plug each one in again with Remote access on to give it back.",
            PrimaryButtonText = "Reset",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary && await _remote.ResetIdentityAsync() is { } said) ShowError(said);
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not reset this PC's identity. See the log for details.");
        }
        ShowRemote();
    }

    /// <summary>"use1-1.relay.n0.iroh.link" for "https://use1-1.relay.n0.iroh.link./".</summary>
    private static string RelayName(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) ? uri.Host.TrimEnd('.') : url;

    private async void OnRemoteToggled(object sender, RoutedEventArgs e)
    {
        if (_remote is null) return;
        try
        {
            var withScreen = RemoteSwitch.IsOn && !RemoteAccess.IsInstalled && ScreenWithTurnOn.IsChecked == true;
            if (await _remote.SetEnabledAsync(RemoteSwitch.IsOn, withScreen) is { } said) ShowError(said);
            else ErrorBox.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not change Remote access. See the log for details.");
        }
        ShowRemote();
        ShowHistoryAndRelay();
    }

    private void OnStopClick(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not PhoneSettingsRow { PhoneId: { } phoneId } || _remote is null) return;
        _ = _remote.DisconnectAsync(phoneId);
        ShowRemote();
        ShowHistoryAndRelay();
    }

    private async void OnRevokeClick(object sender, RoutedEventArgs e)
    {
        if (_revoking || _remote is null) return;
        _revoking = true;
        if (((FrameworkElement)sender).DataContext is not PhoneSettingsRow { PhoneId: { } phoneId } phone) { _revoking = false; return; }
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = $"Take away {phone.Title}'s access?",
                Content = "Its shells and any view of the screen end now, and it can't open new ones. It stays paired; plug it in again with Remote access on to give it back.",
                PrimaryButtonText = "Revoke",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) await _remote.RevokeAsync(phoneId);
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not revoke its access. See the log for details.");
        }
        finally
        {
            _revoking = false;
        }
        ShowRemote();
        ShowHistoryAndRelay();
    }

    /// <summary>In front of whatever is there: opened from the tray, the window would otherwise come up behind it.</summary>
    public void BringToFront()
    {
        Activate();
        _ = NativeMethods.BringToFront(Win32Interop.GetWindowFromWindowId(AppWindow.Id));
    }

    /// <summary>The folder with passthrough.log, in Explorer (the service's own log is under ProgramData, for administrators).</summary>
    private void OnOpenLogClick(object sender, RoutedEventArgs e)
    {
        try
        {
            if (System.IO.Path.GetDirectoryName(LogFile.Path) is { } folder)
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe") { ArgumentList = { folder }, UseShellExecute = false });
        }
        catch (Exception ex) { LogFile.Error(ex); }
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorBox.Visibility = Visibility.Visible;
    }
}
