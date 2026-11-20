using System.Windows.Input;

namespace Passthrough.App.Platform;

/// <summary>An <see cref="ICommand"/> that runs a delegate; the tray icon's click and menu take commands.</summary>
internal sealed class ActionCommand(Action run) : ICommand
{
    // The command is always runnable, so this never fires.
    public event EventHandler? CanExecuteChanged { add { } remove { } }

    public bool CanExecute(object? parameter) => true;

    public void Execute(object? parameter) => run();
}
