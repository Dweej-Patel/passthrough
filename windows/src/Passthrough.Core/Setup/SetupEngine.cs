using System.Text.Json;
using System.Text.Json.Serialization;

namespace Passthrough.Core.Setup;

public enum StepState { Running, Done, Skipped, Failed }

/// <summary>One line the elevated process reports per step (stage 4 plan, section 3).</summary>
public sealed record StepReport(string Step, StepState State, string? Detail = null);

/// <summary>What the elevated process reports last.</summary>
public sealed record SetupResult
{
    public const string Ok = "ok";
    public const string Failed = "failed";
    public const string Declined = "declined";

    public required string Result { get; init; }
    public string? FailedStep { get; init; }
    public string? Error { get; init; }
    public bool Undone { get; init; }
    /// <summary>It failed before changing anything (the first step refused).</summary>
    public bool Refused { get; init; }
    public string? InstallFolder { get; init; }
    public string? Build { get; init; }

    /// <summary>The process's exit code: 0 ok, 2 failed and undone, 3 failed and not fully undone, 4 refused before changing anything.</summary>
    public int ExitCode => Result == Ok ? 0 : Refused ? 4 : Undone ? 2 : 3;
}

/// <summary>
/// The lines on the result pipe, one JSON object each: <c>{"step":…,"state":…,"detail":…}</c> per step, then
/// <c>{"result":…,…}</c>. What the tray app reads to show progress and the failing step's sentence.
/// </summary>
public static class SetupLines
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static string Encode(StepReport report) => JsonSerializer.Serialize(report, Options);

    public static string Encode(SetupResult result) => JsonSerializer.Serialize(result, Options);

    /// <summary>A step line, a result line, or neither (null, null) for anything else.</summary>
    public static (StepReport? Step, SetupResult? Result) Decode(string line)
    {
        try
        {
            using var doc = JsonDocument.Parse(line);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return (null, null);
            if (doc.RootElement.TryGetProperty("result", out _)) return (null, doc.RootElement.Deserialize<SetupResult>(Options));
            if (doc.RootElement.TryGetProperty("step", out _)) return (doc.RootElement.Deserialize<StepReport>(Options), null);
        }
        catch (Exception e) when (e is JsonException or NotSupportedException) { }
        return (null, null);
    }
}

/// <summary>What a run of a plan carries from step to step.</summary>
public sealed class SetupContext
{
    public required SetupSystem System { get; init; }
    /// <summary>The folder the elevated exe runs from: the build being installed.</summary>
    public required string Source { get; init; }
    /// <summary>The account that asked (from the result pipe's other end), as a SID.</summary>
    public string? AskingAccount { get; init; }
    /// <summary>Read from <see cref="Source"/> by the check step.</summary>
    public FileManifest? Manifest { get; set; }
    /// <summary>install.json as it was when the run began (null: none).</summary>
    public InstallState? Before { get; set; }
    /// <summary>install.json as this run leaves it.</summary>
    public InstallState? State { get; set; }
    /// <summary>The folder the build is (being) installed in.</summary>
    public string? InstallFolder { get; set; }

    /// <summary>
    /// A relay to use (from the setup pipe, never the command line): its URL (null keeps what is set; "" n0's), and
    /// its token (null keeps it; "" none). The install carries stage 3's choice over in the same prompt.
    /// </summary>
    public string? RelayUrl { get; init; }
    public string? RelayToken { get; init; }

    /// <summary>The Remote Desktop step added the asking account to Remote Desktop Users in this run (its undo removes only that).</summary>
    public bool AddedUser { get; set; }

    public SetupMachine Machine => System.Machine;
}

/// <summary>
/// One idempotent thing a plan does. <see cref="Apply"/> returns <see cref="StepState.Done"/> when it changed
/// something (and so must be undone if a later step fails) or <see cref="StepState.Skipped"/> when the PC was already
/// so; it throws <see cref="SetupException"/> to fail.
/// </summary>
public interface ISetupStep
{
    string Id { get; }

    StepState Apply(SetupContext context);

    void Undo(SetupContext context);
}

/// <summary>A step from two functions.</summary>
public sealed class SetupStep(string id, Func<SetupContext, StepState> apply, Action<SetupContext>? undo = null) : ISetupStep
{
    public string Id => id;
    public StepState Apply(SetupContext context) => apply(context);
    public void Undo(SetupContext context) => undo?.Invoke(context);
}

/// <summary>
/// Runs a plan in order. When a step fails, every step that was <see cref="StepState.Done"/> in this run is undone
/// in reverse, after the failing step's own undo (it may have done part of its work, so every undo must cope with
/// that); skipped ones aren't. With <paramref name="continuePastFailure"/> (removal) every step runs whatever
/// fails before it, and nothing is undone.
/// </summary>
public static class SetupEngine
{
    public static SetupResult Run(IReadOnlyList<ISetupStep> plan, SetupContext context, Action<StepReport> report, bool continuePastFailure = false)
    {
        var done = new Stack<ISetupStep>();
        string? firstFailed = null;
        string? firstError = null;
        foreach (var step in plan)
        {
            report(new StepReport(step.Id, StepState.Running));
            try
            {
                var state = step.Apply(context);
                if (state == StepState.Done) done.Push(step);
                report(new StepReport(step.Id, state));
            }
            catch (Exception e) when (e is SetupException or IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception
                or System.Runtime.InteropServices.COMException or InvalidOperationException or ArgumentException)
            {
                var sentence = e is SetupException ? e.Message : $"{e.GetType().Name}: {e.Message}";
                report(new StepReport(step.Id, StepState.Failed, sentence));
                firstFailed ??= step.Id;
                firstError ??= sentence;
                if (continuePastFailure) continue;
                var refused = done.Count == 0 && ReferenceEquals(step, plan[0]);
                // The failing step first: it may have done part of its work.
                done.Push(step);
                var undone = UndoAll(done, context, report);
                return new SetupResult { Result = SetupResult.Failed, FailedStep = step.Id, Error = sentence, Undone = undone, Refused = refused };
            }
        }
        return firstFailed is null
            ? new SetupResult { Result = SetupResult.Ok, InstallFolder = context.InstallFolder, Build = context.Manifest?.Build }
            : new SetupResult { Result = SetupResult.Failed, FailedStep = firstFailed, Error = firstError, Undone = false };
    }

    private static bool UndoAll(Stack<ISetupStep> done, SetupContext context, Action<StepReport> report)
    {
        var all = true;
        while (done.TryPop(out var step))
        {
            try
            {
                step.Undo(context);
                report(new StepReport(step.Id, StepState.Skipped, "undone"));
            }
            catch (Exception e) when (e is SetupException or IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception
                or System.Runtime.InteropServices.COMException or InvalidOperationException or ArgumentException)
            {
                all = false;
                report(new StepReport(step.Id, StepState.Failed, $"couldn't be undone: {e.Message}"));
            }
        }
        return all;
    }
}
