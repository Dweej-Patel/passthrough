using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Passthrough.Core.Presentation;
using Passthrough.Core.Session;

namespace Passthrough.App;

/// <summary>
/// One phone as the flyout shows it: Core's <see cref="PhoneRowModel"/> (all the rules, tested there) with its booleans
/// as <see cref="Visibility"/>, plus the code being typed. The same row object lives as long as the phone stays attached
/// and is refreshed in place, so a code being typed survives the live status updates.
/// </summary>
public sealed class PhoneRow : ObservableBase
{
    // Solid colours that read on a light and a dark card alike (the Mac's mint, amber and red). Rows are only made on
    // the UI thread, which is where brushes must be made.
    private static readonly Brush GoodDot = new SolidColorBrush(ColorHelper.FromArgb(0xFF, 0x3D, 0xD9, 0xA0));
    private static readonly Brush AttentionDot = new SolidColorBrush(ColorHelper.FromArgb(0xFF, 0xFF, 0xB8, 0x4D));
    private static readonly Brush ProblemDot = new SolidColorBrush(ColorHelper.FromArgb(0xFF, 0xE5, 0x54, 0x4A));
    private static readonly Brush NeutralDot = new SolidColorBrush(ColorHelper.FromArgb(0xFF, 0x8A, 0x8F, 0x98));

    private PhoneRowModel _model;
    private string _code = "";
    private string _codeProblem = "";

    public PhoneRow(PhoneEntry entry) => _model = PhoneRowModel.From(entry);

    public string Id => _model.Id;
    public long Attachment => _model.Attachment;
    public string Marker => _model.Marker;
    public string Title => _model.Title;
    public string Detail => _model.Detail;
    public string StateText => _model.StateText;
    public string StatusLine => _model.StatusLine;
    public string ActivityLine => _model.ActivityLine;
    public string Message => _model.Message;
    public bool CanPair => _model.CanPair;

    public string Glyph => Glyphs.For(_model.Kind);

    /// <summary>The phone in use has its picture filled in; the others are outlined by the plain one.</summary>
    public Visibility ActiveVisibility => Show(_model.IsActive);
    public Visibility InactiveVisibility => Show(!_model.IsActive);

    /// <summary>A spinner while something is under way, else a dot in the colour of <see cref="PhoneRowModel.Tone"/>.</summary>
    public Visibility BusyVisibility => Show(_model.Busy);
    public Visibility DotVisibility => Show(!_model.Busy);
    public Brush Dot => _model.Tone switch
    {
        RowTone.Good => GoodDot,
        RowTone.Attention => AttentionDot,
        RowTone.Problem => ProblemDot,
        _ => NeutralDot,
    };

    public Visibility StatusVisibility => Show(_model.ShowStatus);
    public Visibility ActivityVisibility => Show(_model.ShowActivity);
    public Visibility MessageVisibility => Show(_model.ShowMessage);
    public Visibility PairVisibility => Show(_model.ShowPair);
    public Visibility RetryVisibility => Show(_model.ShowRetry);
    public Visibility UseVisibility => Show(_model.ShowUse);
    public Visibility ForgetVisibility => Show(_model.ShowForget);

    public string Code
    {
        get => _code;
        set
        {
            if (_code == value) return;
            _code = value;
            Raise(nameof(Code));
            CodeProblem = "";
        }
    }

    /// <summary>Said under the box when Pair was pressed without six digits in it.</summary>
    public string CodeProblem
    {
        get => _codeProblem;
        set
        {
            if (_codeProblem == value) return;
            _codeProblem = value;
            Raise(nameof(CodeProblem));
            Raise(nameof(CodeProblemVisibility));
        }
    }

    public Visibility CodeProblemVisibility => Show(_codeProblem.Length > 0);

    public void Update(PhoneEntry entry)
    {
        _model = PhoneRowModel.From(entry);
        Raise(string.Empty);
    }

    private static Visibility Show(bool on) => on ? Visibility.Visible : Visibility.Collapsed;
}
