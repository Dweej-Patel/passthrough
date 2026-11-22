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
    private System.Drawing.Icon? _attention;
    private int _waiting;

    public TrayIcon(Action toggleFlyout, Action openSettings, Action quit, Action openFlyout)
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
        // A Windows notification about something that needs the person opens the flyout, where it can be answered.
        _icon.TrayIcon.MessageWindow.MouseEventReceived += (_, e) =>
        {
            if (e.MouseEvent == H.NotifyIcon.Core.MouseEvent.BalloonToolTipClicked) openFlyout();
        };
    }

    /// <summary>
    /// How many notices wait in the flyout: with any, the icon carries an amber dot and its tooltip says so, since the
    /// flyout is otherwise only seen when someone thinks to open it.
    /// </summary>
    public void ShowWaiting(int count)
    {
        if (count == _waiting) return;
        _waiting = count;
        _icon.UpdateIcon(count > 0 ? _attention ??= WithDot(_image) : _image);
        _icon.ToolTipText = count switch
        {
            0 => "Passthrough",
            1 => "Passthrough · 1 thing needs you",
            _ => $"Passthrough · {count} things need you",
        };
    }

    /// <summary>A Windows notification from the icon; clicking it opens the flyout.</summary>
    public void Notify(string title, string text) =>
        _icon.ShowNotification(title, text, H.NotifyIcon.Core.NotificationIcon.Info, sound: true, respectQuietTime: true);

    /// <summary>The icon with an amber dot in its lower right, the notification area's way of saying "look here".</summary>
    private static System.Drawing.Icon WithDot(System.Drawing.Icon icon)
    {
        using var bitmap = icon.ToBitmap();
        using (var g = System.Drawing.Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            var d = Math.Max(6, bitmap.Width * 9 / 16);
            var box = new System.Drawing.Rectangle(bitmap.Width - d, bitmap.Height - d, d - 1, d - 1);
            using var ring = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(255, 32, 32, 32));
            using var amber = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(255, 255, 184, 77));
            g.FillEllipse(ring, box);
            box.Inflate(-Math.Max(1, d / 6), -Math.Max(1, d / 6));
            g.FillEllipse(amber, box);
        }
        var handle = bitmap.GetHicon();
        // A copy that owns its own handle, so the one GetHicon made can be freed now.
        using var made = System.Drawing.Icon.FromHandle(handle);
        var owned = (System.Drawing.Icon)made.Clone();
        NativeMethods.DestroyIcon(handle);
        return owned;
    }

    public void Dispose()
    {
        _icon.Dispose();
        _image.Dispose();
        _attention?.Dispose();
    }
}
