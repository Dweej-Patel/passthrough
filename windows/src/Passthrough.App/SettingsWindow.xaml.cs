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
    private const int WidthDip = 560;
    private const int HeightDip = 760;

    private bool _forgetting;
    private bool _revoking;
    private readonly RemoteAccess? _remote;

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

    /// <summary>The phones allowed to open shells here.</summary>
    public ObservableCollection<RemotePhoneRow> WithAccess { get; } = new();

    /// <summary>The stored pairings, as Core's <see cref="PairedPhone.List"/> names them.</summary>
    public ObservableCollection<PairedPhoneRow> Paired { get; } = new();

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
            var list = await ViewModel.PairedPhonesAsync();
            Paired.Clear();
            foreach (var phone in list) Paired.Add(new PairedPhoneRow(phone));
            NoPairingsText.Visibility = Paired.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
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
        var phone = (PairedPhoneRow)((FrameworkElement)sender).DataContext;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = $"Forget {phone.Title}?",
                Content = "This PC will no longer be paired with it. You can pair again with the code the phone shows.",
                PrimaryButtonText = "Forget pairing",
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
            RemoteAccessState.Off => "Off. Phones can't reach this PC's shell.",
            RemoteAccessState.Starting => "Starting…",
            RemoteAccessState.On when _remote.HomeRelay is { } relay =>
                $"On. Phones you've plugged in once reach this PC from anywhere, directly or through {RelayName(relay)}. Works while Passthrough is open and you're signed in.",
            RemoteAccessState.On => "On. Phones you've plugged in once reach this PC directly; looking for a relay for when they're away. Works while Passthrough is open and you're signed in.",
            _ => _remote.Problem ?? "Remote access couldn't start. See the log for details.",
        };
        if (RemoteSwitch.IsOn != _remote.Enabled)
        {
            RemoteSwitch.Toggled -= OnRemoteToggled;
            RemoteSwitch.IsOn = _remote.Enabled;
            RemoteSwitch.Toggled += OnRemoteToggled;
        }
        var shells = _remote.Catalog.Shells.Select(s => s.Name).ToList();
        ShellsText.Text = shells.Count == 0 ? "" : $"Shells: {string.Join(", ", shells)}. They open as you, never as administrator.";
        var connected = _remote.ConnectedPhones.ToHashSet();
        WithAccess.Clear();
        foreach (var phone in _remote.Access.Phones)
            WithAccess.Add(new RemotePhoneRow(phone.PhoneId, phone.Label, phone.PairingSlot, connected.Contains(phone.PhoneId), _remote.Sessions.RunningSessions(phone.PhoneId)));
        NoAccessText.Visibility = WithAccess.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
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
            : "Phones away from this network reach this PC through n0's public relays. They carry only encrypted traffic.";
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
            // An empty token box keeps the token kept for this relay; n0's relays take none.
            await _remote.SetRelayAsync(url.Length == 0 ? null : url, RelayTokenBox.Password.Length == 0 ? null : RelayTokenBox.Password);
            ErrorBox.Visibility = Visibility.Collapsed;
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
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) await _remote.ResetIdentityAsync();
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
            await _remote.SetEnabledAsync(RemoteSwitch.IsOn);
            ErrorBox.Visibility = Visibility.Collapsed;
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
        var phone = (RemotePhoneRow)((FrameworkElement)sender).DataContext;
        _remote?.Disconnect(phone.PhoneId);
        ShowRemote();
        ShowHistoryAndRelay();
    }

    private async void OnRevokeClick(object sender, RoutedEventArgs e)
    {
        if (_revoking || _remote is null) return;
        _revoking = true;
        var phone = (RemotePhoneRow)((FrameworkElement)sender).DataContext;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = $"Take away {phone.Title}'s access?",
                Content = "Its shells on this PC end now, and it can't open new ones. Plug it in again with Remote access on to give it back.",
                PrimaryButtonText = "Revoke",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) _remote.Revoke(phone.PhoneId);
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

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorBox.Visibility = Visibility.Visible;
    }
}
