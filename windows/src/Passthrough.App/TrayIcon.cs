using H.NotifyIcon;
using Microsoft.UI.Xaml.Controls;
using Passthrough.App.Platform;

namespace Passthrough.App;

/// <summary>
/// The notification-area icon: left-click opens or closes the flyout, the right-click menu has Settings… and Quit.
/// Built in code because the icon has no visual tree to live in.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private readonly System.Drawing.Icon _image;
    private readonly TaskbarIcon _icon;

    public TrayIcon(Action toggleFlyout, Action openSettings, Action quit)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(new MenuFlyoutItem { Text = "Settings…", Command = new ActionCommand(openSettings) });
        menu.Items.Add(new MenuFlyoutItem { Text = "Quit", Command = new ActionCommand(quit) });

        // Loaded here, not through IconSource: H.NotifyIcon loads an IconSource in an async void callback, where a missing
        // or damaged file would be an unhandled exception instead of a startup failure. Reading the handle decodes it now.
        // At the size the notification area draws (16 pixels at 100 %), so Windows doesn't shrink a bigger one into a blur.
        var size = NativeMethods.SmallIconSize();
        _image = new System.Drawing.Icon(AppIcon.Path, size, size);
        _ = _image.Handle;

        _icon = new TaskbarIcon
        {
            ToolTipText = "Passthrough",
            Icon = _image,
            ContextFlyout = menu,
            ContextMenuMode = ContextMenuMode.PopupMenu,
            LeftClickCommand = new ActionCommand(toggleFlyout),
            NoLeftClickDelay = true,
        };
        // H.NotifyIcon would otherwise put the whole process in Efficiency Mode (EcoQoS and idle priority) until its own
        // Show/Hide helpers lift it, which this app doesn't use: the heartbeat and the UI would be starved on a busy PC.
        _icon.ForceCreate(enablesEfficiencyMode: false);
    }

    public void Dispose()
    {
        _icon.Dispose();
        _image.Dispose();
    }
}
