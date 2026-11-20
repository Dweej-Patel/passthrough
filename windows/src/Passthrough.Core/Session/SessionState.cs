using Passthrough.Core.Transport;

namespace Passthrough.Core.Session;

/// <summary>An immutable snapshot of the session: attached phones, oldest first, and how each watcher is doing.</summary>
public sealed record SessionState(IReadOnlyList<PhoneEntry> Phones, WatchStatus UsbMux, WatchStatus Adb);
