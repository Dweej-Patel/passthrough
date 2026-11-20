using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Passthrough.App.Platform;
using Passthrough.Core.Presentation;

namespace Passthrough.App;

/// <summary>Android support, start at login, and forgetting any stored pairing (its phone attached or not).</summary>
public sealed partial class SettingsWindow : Window
{
    private bool _forgetting;

    public SettingsWindow(SessionViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();

        // Set the switches before listening, so loading the saved values does not count as a change.
        AndroidSwitch.IsOn = viewModel.AndroidEnabled;
        StartAtLoginSwitch.IsOn = ReadStartAtLogin();
        AndroidSwitch.Toggled += OnAndroidToggled;
        StartAtLoginSwitch.Toggled += OnStartAtLoginToggled;

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

    /// <summary>The stored pairings, as Core's <see cref="PairedPhone.List"/> names them.</summary>
    public ObservableCollection<PairedPhone> Paired { get; } = new();

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
            foreach (var phone in list) Paired.Add(phone);
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
            ErrorText.Visibility = Visibility.Collapsed;
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
            ErrorText.Visibility = Visibility.Collapsed;
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
        var phone = (PairedPhone)((FrameworkElement)sender).DataContext;
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
                ErrorText.Visibility = Visibility.Collapsed;
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

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }
}
