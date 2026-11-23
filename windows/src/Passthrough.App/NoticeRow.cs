using Microsoft.UI.Xaml;
using Passthrough.Core.Pipe;

namespace Passthrough.App;

/// <summary>A notice from Remote access in the flyout, until it is answered.</summary>
public sealed class NoticeRow(PipeNotice notice)
{
    public PipeNotice Notice { get; } = notice;
    public string Text => Notice.Text;

    /// <summary>The notice's one action: a newly granted phone may also see the screen; a computer let in can be revoked; an exposure opens Settings.</summary>
    public string ActionText => Notice.Kind switch
    {
        PipeNotice.Granted or PipeNotice.ComputerScreenPending => "Allow screen",
        PipeNotice.ComputerGranted => "Revoke…",
        PipeNotice.Exposed => "Open Settings",
        _ => "",
    };
    public Visibility ActionVisibility => ActionText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Revoke asks first, beside the button.</summary>
    public bool ActionAsks => Notice.Kind == PipeNotice.ComputerGranted;

    /// <summary>The action opens Settings ▸ Remote access instead of answering the notice (an exposure goes by itself once closed).</summary>
    public bool ActionOpensSettings => Notice.Kind == PipeNotice.Exposed;

    /// <summary>"Not now" beside Allow screen, "OK" otherwise; none for an exposure, which goes once Remote Desktop is closed again.</summary>
    public string DismissText => Notice.Kind is PipeNotice.Granted or PipeNotice.ComputerScreenPending ? "Not now" : "OK";
    public Visibility DismissVisibility => Notice.Kind == PipeNotice.Exposed ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>The Windows notification's title, saying what happened.</summary>
    public static string ToastTitle(PipeNotice notice) => notice.Kind switch
    {
        PipeNotice.Granted => "A phone can now reach this PC",
        PipeNotice.ComputerScreenPending => "A computer is waiting for this PC's screen",
        PipeNotice.ComputerGranted => "A computer can now reach this PC",
        PipeNotice.Exposed => "Remote Desktop is open to the network",
        _ => "Passthrough",
    };
}
