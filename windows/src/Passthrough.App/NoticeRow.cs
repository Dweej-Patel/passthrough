using Microsoft.UI.Xaml;
using Passthrough.Core.Pipe;

namespace Passthrough.App;

/// <summary>A notice from Remote access in the flyout, until it is answered.</summary>
public sealed class NoticeRow(PipeNotice notice)
{
    public PipeNotice Notice { get; } = notice;
    public string Text => Notice.Text;

    /// <summary>The one action beside OK: a newly granted phone may also see the screen.</summary>
    public string ActionText => Notice.Kind switch
    {
        PipeNotice.Granted or PipeNotice.ComputerScreenPending => "Allow screen",
        PipeNotice.ComputerGranted => "Revoke",
        _ => "",
    };
    public Visibility ActionVisibility => ActionText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    /// <summary>An exposure notice goes by itself once Remote Desktop is closed again: no OK.</summary>
    public Visibility OkVisibility => Notice.Kind == PipeNotice.Exposed ? Visibility.Collapsed : Visibility.Visible;
}
