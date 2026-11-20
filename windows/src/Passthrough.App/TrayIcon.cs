using H.NotifyIcon;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Passthrough.App.Platform;

namespace Passthrough.App;

/// <summary>
/// The notification-area icon: left-click opens or closes the flyout, the right-click menu has Settings… and Quit.
/// Built in code because the icon has no visual tree to live in.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private readonly TaskbarIcon _icon;

    public TrayIcon(Action toggleFlyout, Action openSettings, Action quit)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(new MenuFlyoutItem { Text = "Settings…", Command = new ActionCommand(openSettings) });
        menu.Items.Add(new MenuFlyoutItem { Text = "Quit", Command = new ActionCommand(quit) });

        _icon = new TaskbarIcon
        {
            ToolTipText = "Passthrough",
            IconSource = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "tray.ico"))),
            ContextFlyout = menu,
            ContextMenuMode = ContextMenuMode.PopupMenu,
            LeftClickCommand = new ActionCommand(toggleFlyout),
            NoLeftClickDelay = true,
        };
        // H.NotifyIcon would otherwise put the whole process in Efficiency Mode (EcoQoS and idle priority) until its own
        // Show/Hide helpers lift it, which this app doesn't use: the heartbeat and the UI would be starved on a busy PC.
        _icon.ForceCreate(enablesEfficiencyMode: false);
    }

    public void Dispose() => _icon.Dispose();
}
