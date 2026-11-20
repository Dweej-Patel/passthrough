using Microsoft.UI.Xaml;
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
