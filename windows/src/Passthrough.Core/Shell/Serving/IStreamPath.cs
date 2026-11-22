namespace Passthrough.Core.Shell.Serving;

/// <summary>
/// A connection that can say how it reaches the peer right now ("iroh, direct", "iroh, through relay x"), for the
/// log line of each screen view. Never the peer's address: the log names paths, not people's networks.
/// </summary>
public interface IStreamPath
{
    string DescribePath();
}
