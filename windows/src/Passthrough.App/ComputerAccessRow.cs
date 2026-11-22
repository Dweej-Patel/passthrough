using Passthrough.Core.Pipe;

namespace Passthrough.App;

/// <summary>A computer a phone gave access to this PC, as Settings ▸ Remote access ▸ Computers with access lists it.</summary>
public sealed class ComputerAccessRow(PipeComputer computer)
{
    public string Id { get; } = computer.Id;
    public string Title { get; } = computer.Name;

    /// <summary>"Mac · from iPhone · Connected", and what waits for the owner.</summary>
    public string Detail { get; } = string.Join(" · ", new[]
    {
        computer.Kind switch { "mac" => "Mac", "windows" => "PC", _ => null },
        $"from {computer.GrantedBy}",
        computer.Connections > 0 ? "Connected" : null,
        computer.ScreenPending ? "Screen waits for you" : null,
    }.Where(part => part is not null));

    /// <summary>It may see the screen now.</summary>
    public bool Screen { get; } = computer.Screen;

    /// <summary>The screen was handed to it: the box can be ticked (and unticked). Without it, only the phone can give it.</summary>
    public bool ScreenSwitchEnabled { get; } = computer.Screen || computer.ScreenPending;

    public string ScreenTip { get; } = computer.Screen || computer.ScreenPending
        ? "Let it see and control this PC's screen. Windows still asks for your password."
        : "The phone gave it the shell only. To give it the screen too, share again from the phone.";

    public string Glyph => computer.Kind == "mac" ? Glyphs.Laptop : Glyphs.Desktop;
}
