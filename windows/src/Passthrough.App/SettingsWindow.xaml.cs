using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Passthrough.App.Platform;

namespace Passthrough.App;

/// <summary>Android support, start at login, and forgetting a phone's pairing.</summary>
public sealed partial class SettingsWindow : Window
{
    public SettingsWindow(SessionViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();

        // Set the switches before listening, so loading the saved values does not count as a change.
        AndroidSwitch.IsOn = viewModel.AndroidEnabled;
        StartAtLoginSwitch.IsOn = StartupRegistration.IsEnabled();
        AndroidSwitch.Toggled += OnAndroidToggled;
        StartAtLoginSwitch.Toggled += OnStartAtLoginToggled;
    }

    public SessionViewModel ViewModel { get; }

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
            // Show the setting as it really is, without running this handler again.
            AndroidSwitch.Toggled -= OnAndroidToggled;
            AndroidSwitch.IsOn = ViewModel.AndroidEnabled;
            AndroidSwitch.Toggled += OnAndroidToggled;
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
            StartAtLoginSwitch.IsOn = StartupRegistration.IsEnabled();
            StartAtLoginSwitch.Toggled += OnStartAtLoginToggled;
            ShowError("Could not change Start at login.");
        }
    }

    private async void OnForgetClick(object sender, RoutedEventArgs e)
    {
        var row = (PhoneRow)((FrameworkElement)sender).DataContext;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = $"Forget {row.Title}?",
                Content = "This PC will no longer be paired with it. You can pair again with the code the phone shows.",
                PrimaryButtonText = "Forget pairing",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) await ViewModel.ForgetAsync(row.Id);
        }
        catch (Exception ex)
        {
            LogFile.Error(ex);
            ShowError("Could not forget the pairing. See the log for details.");
        }
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }
}
