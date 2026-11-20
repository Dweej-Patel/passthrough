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
        try { await ViewModel.SetAndroidEnabledAsync(AndroidSwitch.IsOn); }
        catch (Exception ex) { LogFile.Error(ex); }
    }

    private void OnStartAtLoginToggled(object sender, RoutedEventArgs e)
    {
        try { StartupRegistration.SetEnabled(StartAtLoginSwitch.IsOn); }
        catch (Exception ex) { LogFile.Error(ex); }
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
        catch (Exception ex) { LogFile.Error(ex); }
    }
}
