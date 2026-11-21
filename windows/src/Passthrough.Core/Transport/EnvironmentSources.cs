namespace Passthrough.Core.Transport;

/// <summary>
/// Where <see cref="AdbLocator"/> reads environment variables, each read again on every search so a change made after
/// Passthrough started (platform-tools installed, PATH edited) is seen without a restart.
/// </summary>
/// <param name="Process">The process's own environment: the snapshot taken when it started (and anything its launcher set).</param>
/// <param name="User">
/// The user's stored environment (on Windows, <c>HKCU\Environment</c>), or null. A read that throws counts as unset.
/// </param>
/// <param name="Machine">
/// The machine's stored environment (on Windows, <c>HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment</c>),
/// or null. A read that throws counts as unset.
/// </param>
public sealed record EnvironmentSources(
    Func<string, string?> Process,
    Func<string, string?>? User = null,
    Func<string, string?>? Machine = null);
