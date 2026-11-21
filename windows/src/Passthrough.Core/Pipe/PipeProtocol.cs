namespace Passthrough.Core.Pipe;

/// <summary>The pipe between the service and the tray app (stage 4 plan, section 4): its name and version.</summary>
public static class PipeProtocol
{
    /// <summary>Goes up by one whenever a frame's meaning or layout changes (a new optional field or kind doesn't need it).</summary>
    public const int Version = 1;
    public const int MinimumVersion = 1;
    public const string Name = "PassthroughService";
}
