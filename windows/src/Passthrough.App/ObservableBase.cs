using System.ComponentModel;

namespace Passthrough.App;

/// <summary>Minimal <see cref="INotifyPropertyChanged"/> for the view models.</summary>
public abstract class ObservableBase : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Tells bindings that <paramref name="name"/> changed; the empty string means every property.</summary>
    protected void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
