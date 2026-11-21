namespace Passthrough.Core.Setup;

/// <summary>
/// The elevated verbs as ordered steps (stage 4 plan, section 3), over <see cref="SetupSystem"/>'s interfaces so every
/// step, its idempotence and its undo are tested with fakes. Each step that changes something Windows already had
/// keeps the earlier value in the context before changing it.
/// </summary>
public static class SetupPlans
{
    public const string Install = "install";
    public const string Update = "update";
    public const string Off = "off";
    public const string Remove = "remove";
    public const string Allow = "allow";
    public const string Disallow = "disallow";

    private static readonly TimeSpan ServiceWait = TimeSpan.FromSeconds(20);

    /// <summary>What the service runs: the exe at the path that never changes.</summary>
    public static string BinaryPath(SetupMachine machine) => $"\"{machine.ServiceExe}\" --service";

    /// <summary>
    /// <c>--install</c> (also what Turn on runs after <c>--off</c>, and a repair) and <c>--update</c>: both copy the
    /// build into a fresh folder and point everything at it; an update needs an install to update.
    /// </summary>
    public static IReadOnlyList<ISetupStep> InstallOrUpdate(bool update) =>
    [
        Check(update),
        DataFolder(),
        WriteState(),
        Stage(),
        Verify(),
        StopForChange(),
        Launcher(),
        ServiceStep(),
        Firewall(),
        PublicState(),
        Shortcut(),
        Relay(),
        Start(),
        Tidy(),
    ];

    /// <summary><c>--configure relay</c>: the relay (URL and token from the setup pipe) for phones away from this network.</summary>
    public static IReadOnlyList<ISetupStep> ConfigureRelay() =>
    [
        new SetupStep("check", c =>
        {
            c.Before = ReadState(c) ?? throw new SetupException("Remote access isn't set up on this PC.");
            c.State = c.Before;
            return StepState.Skipped;
        }),
        Relay(),
        new SetupStep("state", c =>
        {
            c.System.Files.Write(c.Machine.StateFile, c.State!.Encode());
            return StepState.Done;
        }, c => c.System.Files.Write(c.Machine.StateFile, c.Before!.Encode())),
        Reload(),
    ];

    /// <summary><c>--configure reset-identity</c>: the service makes a new identity; every phone's access goes with the old one.</summary>
    public static IReadOnlyList<ISetupStep> ResetIdentity() =>
    [
        new SetupStep("check", c =>
        {
            if (ReadState(c) is null) throw new SetupException("Remote access isn't set up on this PC.");
            return StepState.Skipped;
        }),
        new SetupStep("reset", c =>
        {
            c.System.Files.Write(c.Machine.PendingReset, "reset"u8.ToArray());
            return StepState.Done;
        }, c => c.System.Files.DeleteFile(c.Machine.PendingReset)),
        Reload(),
    ];

    /// <summary>Tells a running service to re-read what administrators wrote (a stopped one reads it as it starts).</summary>
    private static ISetupStep Reload() => new SetupStep("reload", c =>
        c.System.Service.SendControl(ServiceDefinition.ControlReload) ? StepState.Done : StepState.Skipped);

    /// <summary>
    /// The relay, when the setup pipe named one: its URL into install.json (the service reads it), its token into a
    /// file only administrators and the service can open, which the service moves into its own store.
    /// </summary>
    private static ISetupStep Relay() => new SetupStep("relay", c =>
    {
        if (c.RelayUrl is null && c.RelayToken is null) return StepState.Skipped;
        if (c.RelayUrl is { Length: > 0 } url && !IsRelayUrl(url)) throw new SetupException("A relay is an https:// address with nothing after its path.");
        if (c.RelayUrl is not null) c.State = c.State! with { Relay = new InstallState.RelayState { Url = c.RelayUrl.Length == 0 ? null : c.RelayUrl } };
        var token = c.RelayUrl is { Length: 0 } ? "" : c.RelayToken;
        if (token is not null)
        {
            if (token.Length > 4096) throw new SetupException("That relay token is too long.");
            c.System.Files.Write(c.Machine.PendingRelayToken, System.Text.Encoding.UTF8.GetBytes(token));
        }
        c.System.Files.Write(c.Machine.StateFile, c.State!.Encode());
        return StepState.Done;
    }, c =>
    {
        c.System.Files.DeleteFile(c.Machine.PendingRelayToken);
        if (c.Before is { } before) c.System.Files.Write(c.Machine.StateFile, before.Encode());
    });

    /// <summary>https, a host, no query, fragment or user info (where a token would end up logged), at most 512 characters.</summary>
    public static bool IsRelayUrl(string text) =>
        text.Length <= 512 && Uri.TryCreate(text, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps && uri.Host.Length > 0
        && uri.Query.Length == 0 && uri.Fragment.Length == 0 && uri.UserInfo.Length == 0;

    /// <summary><c>--off</c>: phones can't reach the PC until it is turned on again; files, store and state stay.</summary>
    public static IReadOnlyList<ISetupStep> TurnOff() =>
    [
        new SetupStep("check", c =>
        {
            if (c.System.Service.Query() is null) throw new SetupException("Remote access isn't set up on this PC.");
            return StepState.Skipped;
        }),
        new SetupStep("public-state", c =>
        {
            var values = c.System.Registry.Values();
            if (values.GetValueOrDefault("Enabled") == "0") return StepState.Skipped;
            // First, so the stopping service knows why (it tells phones "turned off").
            c.System.Registry.SetNumber("Enabled", 0);
            return StepState.Done;
        }, c => c.System.Registry.SetNumber("Enabled", 1)),
        new SetupStep("stop", c =>
        {
            if (!c.System.Service.IsRunning()) return StepState.Skipped;
            c.System.Service.Stop(ServiceWait);
            return StepState.Done;
        }, c => c.System.Service.Start(ServiceWait)),
        new SetupStep("start-type", c =>
        {
            if (c.System.Service.Query() is { StartType: ServiceStart.Disabled }) return StepState.Skipped;
            c.System.Service.SetStartType(ServiceStart.Disabled);
            return StepState.Done;
        }, c => c.System.Service.SetStartType(ServiceStart.Automatic)),
        new SetupStep("firewall", c =>
        {
            var on = c.System.Firewall.InGroup().Where(r => r.Enabled && ServiceDefinition.RuleNames.Contains(r.Name)).ToList();
            foreach (var rule in on) c.System.Firewall.SetEnabled(rule.Name, false);
            return on.Count > 0 ? StepState.Done : StepState.Skipped;
        }, c => { foreach (var name in ServiceDefinition.RuleNames) if (c.System.Firewall.InGroup().Any(r => r.Name == name)) c.System.Firewall.SetEnabled(name, true); }),
    ];

    /// <summary>
    /// <c>--remove</c>: undoes everything, in reverse, each step running whatever failed before it. The service
    /// forgets its own key first (only its account can open it). Folders are deleted only when they are Passthrough's.
    /// </summary>
    public static IReadOnlyList<ISetupStep> RemoveAll() =>
    [
        new SetupStep("public-state", c =>
        {
            if (!c.System.Registry.Exists) return StepState.Skipped;
            c.System.Registry.SetNumber("Enabled", 0);
            return StepState.Done;
        }),
        new SetupStep("stop", c =>
        {
            if (c.System.Service.Query() is null) return StepState.Skipped;
            c.System.Service.Stop(ServiceWait);
            return StepState.Done;
        }),
        new SetupStep("service", c =>
        {
            if (c.System.Service.Query() is null) return StepState.Skipped;
            c.System.Service.Delete();
            return StepState.Done;
        }),
        new SetupStep("firewall", c =>
        {
            var ours = c.System.Firewall.InGroup().Select(r => r.Name).Distinct().ToList();
            foreach (var name in ours) c.System.Firewall.Remove(name);
            return ours.Count > 0 ? StepState.Done : StepState.Skipped;
        }),
        new SetupStep("shortcut", c =>
        {
            if (!c.System.Shortcuts.Exists(c.Machine.ShortcutPath)) return StepState.Skipped;
            c.System.Shortcuts.Delete(c.Machine.ShortcutPath);
            return StepState.Done;
        }),
        new SetupStep("registry", c =>
        {
            if (!c.System.Registry.Exists) return StepState.Skipped;
            c.System.Registry.DeleteKey();
            return StepState.Done;
        }),
        DeleteTrustedFolder("data-folder", c => c.Machine.DataFolder),
        DeleteTrustedFolder("program-folder", c => c.Machine.ProgramFolder),
        new SetupStep("service-profile", c => c.System.Service.DeleteProfile() ? StepState.Done : StepState.Skipped),
    ];

    /// <summary><c>--configure allow</c>: the asking account may use the service too.</summary>
    public static IReadOnlyList<ISetupStep> AllowAccount() => ChangeAccounts((state, c) =>
        state.Allowing(c.AskingAccount ?? throw new SetupException("Couldn't tell which account asked.")));

    /// <summary><c>--configure disallow &lt;SID&gt;</c>: that account's phones can't reach this PC any more (their records stay).</summary>
    public static IReadOnlyList<ISetupStep> DisallowAccount(string sid) => ChangeAccounts((state, _) =>
        state with { AllowedAccounts = [.. state.AllowedAccounts.Where(a => !string.Equals(a, sid, StringComparison.OrdinalIgnoreCase))] });

    private static IReadOnlyList<ISetupStep> ChangeAccounts(Func<InstallState, SetupContext, InstallState> change) =>
    [
        new SetupStep("check", c =>
        {
            c.Before = ReadState(c) ?? throw new SetupException("Remote access isn't set up on this PC.");
            c.State = change(c.Before, c);
            return StepState.Skipped;
        }),
        new SetupStep("state", c =>
        {
            if (c.State!.AllowedAccounts.SequenceEqual(c.Before!.AllowedAccounts)) return StepState.Skipped;
            c.System.Files.Write(c.Machine.StateFile, c.State.Encode());
            return StepState.Done;
        }, c => c.System.Files.Write(c.Machine.StateFile, c.Before!.Encode())),
        new SetupStep("service-security", c =>
        {
            c.System.Service.SetSecurity(c.State!.AllowedAccounts);
            return StepState.Done;
        }, c => c.System.Service.SetSecurity(c.Before!.AllowedAccounts)),
    ];

    // MARK: Install and update steps

    internal static InstallState? ReadState(SetupContext c) =>
        c.System.Files.FileExists(c.Machine.StateFile) ? InstallState.Decode(c.System.Files.ReadLocked(c.Machine.StateFile)) : null;

    private static ISetupStep Check(bool update) => new SetupStep("check", c =>
    {
        if (c.Machine.WindowsBuild < ServiceDefinition.MinimumBuild) throw new SetupException("Remote access needs Windows 10 version 1809 or later.");
        var manifestPath = WinPath.Join(c.Source, ServiceDefinition.ManifestName);
        var manifest = c.System.Files.FileExists(manifestPath) ? FileManifest.Decode(c.System.Files.ReadLocked(manifestPath)) : null;
        if (manifest is null)
            throw new SetupException("This copy of Passthrough is incomplete: files.json is missing or damaged. Build it with scripts/build-windows.ps1, then turn Remote access on from that copy.");
        if (!manifest.IsSelfContained)
            throw new SetupException("This build needs .NET installed for every account, which a background service can't count on. Build it with scripts/build-windows.ps1, then turn Remote access on from that copy.");
        if (!manifest.Files.Any(f => string.Equals(f.Path, ServiceDefinition.ExeName, StringComparison.OrdinalIgnoreCase))
            || !manifest.Files.Any(f => string.Equals(f.Path, ServiceDefinition.AppExeName, StringComparison.OrdinalIgnoreCase)))
            throw new SetupException("This copy of Passthrough is incomplete: its background service is missing. Build it with scripts/build-windows.ps1.");
        foreach (var file in manifest.Files)
            if (!c.System.Files.FileExists(WinPath.Join(c.Source, file.Path)))
                throw new SetupException($"This copy of Passthrough is incomplete: {file.Path} is missing. Build it again.");
        c.Manifest = manifest;
        c.Before = ReadState(c);
        if (update && (c.Before is null || c.System.Service.Query() is null))
            throw new SetupException("There's no background service to update. Turn Remote access on instead.");
        // A stray older copy never downgrades what another account installed.
        if (c.Before is { Build.Length: > 0 } installed && CompareBuilds(manifest.Build, installed.Build) < 0)
            throw new SetupException($"This copy of Passthrough ({manifest.Build}) is older than the one installed ({installed.Build}). Open the installed one from the Start menu.");
        var state = (c.Before ?? new InstallState()) with
        {
            InstalledAt = c.System.Time.GetUtcNow().ToUnixTimeSeconds(),
            Build = manifest.Build,
        };
        if (c.AskingAccount is { } asking) state = state.Allowing(asking);
        if (state.AllowedAccounts.Count == 0) throw new SetupException("Couldn't tell which account asked.");
        c.State = state;
        return StepState.Skipped;
    });

    private static ISetupStep DataFolder()
    {
        var created = false;
        return new SetupStep("data-folder", c =>
        {
            created = false;
            var files = c.System.Files;
            switch (files.Check(c.Machine.DataFolder))
            {
                case FolderCheck.Planted:
                    throw new SetupException($"{c.Machine.DataFolder} already exists and wasn't made by Passthrough. Remove or rename it, then try again.");
                case FolderCheck.Missing:
                    files.CreateFolder(c.Machine.DataFolder, ServiceDefinition.DataFolderSddl);
                    created = true;
                    break;
                default:
                    files.SetSecurity(c.Machine.DataFolder, ServiceDefinition.DataFolderSddl);
                    break;
            }
            foreach (var (folder, sddl) in new[] { (c.Machine.StoreFolder, ServiceDefinition.StoreFolderSddl), (c.Machine.LogsFolder, ServiceDefinition.LogsFolderSddl) })
            {
                if (files.FolderExists(folder)) files.SetSecurity(folder, sddl);
                else files.CreateFolder(folder, sddl);
            }
            c.State = c.State! with { Created = c.State.Created with { DataFolder = c.State.Created.DataFolder || created } };
            return created ? StepState.Done : StepState.Skipped;
        }, c => { if (created) c.System.Files.DeleteFolder(c.Machine.DataFolder); });
    }

    private static ISetupStep WriteState() => new SetupStep("state", c =>
    {
        c.System.Files.Write(c.Machine.StateFile, c.State!.Encode());
        return StepState.Done;
    }, c =>
    {
        if (c.Before is { } before) c.System.Files.Write(c.Machine.StateFile, before.Encode());
        else if (c.System.Files.FileExists(c.Machine.StateFile)) c.System.Files.DeleteFile(c.Machine.StateFile);
    });

    private static ISetupStep Stage()
    {
        var createdRoot = false;
        return new SetupStep("stage", c =>
        {
            createdRoot = false;
            var files = c.System.Files;
            switch (files.Check(c.Machine.ProgramFolder))
            {
                case FolderCheck.Planted:
                    throw new SetupException($"{c.Machine.ProgramFolder} already exists and wasn't made by Passthrough. Remove or rename it, then try again.");
                case FolderCheck.Missing:
                    files.CreateFolder(c.Machine.ProgramFolder, ServiceDefinition.ProgramFolderSddl);
                    createdRoot = true;
                    break;
                default:
                    files.SetSecurity(c.Machine.ProgramFolder, ServiceDefinition.ProgramFolderSddl);
                    break;
            }
            // A fresh folder every time, never reused: what runs is exactly what was hashed.
            string folder;
            do folder = WinPath.Join(c.Machine.ProgramFolder, $"{c.Manifest!.FolderName}-{c.System.RandomHex()}");
            while (files.FolderExists(folder));
            c.InstallFolder = folder;
            foreach (var file in c.Manifest.Files)
            {
                var bytes = files.ReadLocked(WinPath.Join(c.Source, file.Path));
                if (bytes.Length != file.Size || FileManifest.Hash(bytes) != file.Sha256)
                    throw new SetupException($"{file.Path} doesn't match this build (it changed after it was built). Build it again.");
                files.WriteNew(WinPath.Join(folder, file.Path), bytes);
            }
            c.State = c.State! with
            {
                InstallFolder = folder,
                Created = c.State.Created with { ProgramFolder = c.State.Created.ProgramFolder || createdRoot },
            };
            return StepState.Done;
        }, c =>
        {
            if (c.InstallFolder is { } folder && c.System.Files.FolderExists(folder)) c.System.Files.DeleteFolder(folder);
            if (createdRoot) c.System.Files.DeleteFolder(c.Machine.ProgramFolder);
            c.InstallFolder = c.Before?.InstallFolder;
        });
    }

    private static ISetupStep Verify() => new SetupStep("verify", c =>
    {
        foreach (var file in c.Manifest!.Files)
        {
            var bytes = c.System.Files.ReadLocked(WinPath.Join(c.InstallFolder!, file.Path));
            if (bytes.Length != file.Size || FileManifest.Hash(bytes) != file.Sha256)
                throw new SetupException($"The copy of {file.Path} didn't match after it was written. Try again.");
        }
        return StepState.Skipped;
    });

    /// <summary>"0.9.0+abc" against "0.10.0+def" by version; equal when either has none.</summary>
    internal static int CompareBuilds(string a, string b) =>
        Version.TryParse(a.Split('+')[0], out var va) && Version.TryParse(b.Split('+')[0], out var vb) ? va.CompareTo(vb) : 0;

    /// <summary>
    /// The exe at the path that never changes is replaced (the service is stopped, so nothing runs it but a moment's
    /// <c>--launch</c>); the bytes it replaces are kept for the undo.
    /// </summary>
    private static ISetupStep Launcher()
    {
        byte[]? before = null;
        return new SetupStep("launcher", c =>
        {
            var files = c.System.Files;
            var target = c.Machine.ServiceExe;
            var bytes = files.ReadLocked(WinPath.Join(c.InstallFolder!, ServiceDefinition.ExeName));
            before = files.FileExists(target) ? files.ReadLocked(target) : null;
            if (before is not null && FileManifest.Hash(before) == FileManifest.Hash(bytes)) return StepState.Skipped;
            files.Write(target, bytes);
            return StepState.Done;
        }, c =>
        {
            if (before is not null) c.System.Files.Write(c.Machine.ServiceExe, before);
            else c.System.Files.DeleteFile(c.Machine.ServiceExe);
        });
    }

    /// <summary>A running service is stopped before it is pointed elsewhere (it is started again at the end).</summary>
    private static ISetupStep StopForChange() => new SetupStep("stop", c =>
    {
        if (!c.System.Service.IsRunning()) return StepState.Skipped;
        // An update or a repair, not a turn-off: the service tells phones nothing and they reconnect.
        c.System.Registry.SetNumber("Updating", 1);
        c.System.Service.Stop(ServiceWait);
        return StepState.Done;
    }, c =>
    {
        c.System.Registry.DeleteValue("Updating");
        c.System.Service.Start(ServiceWait);
    });

    private static ISetupStep ServiceStep()
    {
        ServiceConfig? before = null;
        return new SetupStep("service", c =>
        {
            before = c.System.Service.Query();
            c.System.Service.Configure(BinaryPath(c.Machine), ServiceStart.Automatic, c.State!.AllowedAccounts);
            c.State = c.State with { Created = c.State.Created with { Service = c.State.Created.Service || before is null } };
            return StepState.Done;
        }, c =>
        {
            if (before is null) c.System.Service.Delete();
            else c.System.Service.Configure(before.BinaryPath, before.StartType, c.Before?.AllowedAccounts ?? c.State!.AllowedAccounts);
        });
    }

    private static ISetupStep Firewall()
    {
        IReadOnlyList<FirewallRule> before = [];
        return new SetupStep("firewall", c =>
        {
            var rules = c.System.Firewall;
            before = rules.InGroup();
            // Removed first, so a re-run or an update (whose program path changes) leaves exactly these.
            foreach (var name in before.Select(r => r.Name).Distinct()) rules.Remove(name);
            var wanted = ServiceDefinition.FirewallRules(c.Machine.ProgramFolder, c.InstallFolder!, c.Machine.WindowsBuild);
            foreach (var rule in wanted) rules.Add(rule);
            c.State = c.State! with { FirewallRules = [.. wanted.Select(r => r.Name)] };
            return StepState.Done;
        }, c =>
        {
            var rules = c.System.Firewall;
            foreach (var name in rules.InGroup().Select(r => r.Name).Distinct()) rules.Remove(name);
            foreach (var rule in before) rules.Add(rule);
        });
    }

    private static ISetupStep PublicState()
    {
        IReadOnlyDictionary<string, string>? before = null;
        return new SetupStep("public-state", c =>
        {
            var registry = c.System.Registry;
            before = registry.Exists ? registry.Values() : null;
            registry.Set("InstallFolder", c.InstallFolder!);
            registry.Set("Build", c.Manifest!.Build);
            registry.SetNumber("PipeProtocol", Pipe.PipeProtocol.Version);
            registry.SetNumber("Enabled", 1);
            return StepState.Done;
        }, c =>
        {
            var registry = c.System.Registry;
            if (before is null) { registry.DeleteKey(); return; }
            foreach (var name in new[] { "InstallFolder", "Build" })
                if (before.TryGetValue(name, out var value)) registry.Set(name, value); else registry.DeleteValue(name);
            foreach (var name in new[] { "PipeProtocol", "Enabled" })
                if (before.TryGetValue(name, out var value) && int.TryParse(value, out var number)) registry.SetNumber(name, number); else registry.DeleteValue(name);
        });
    }

    private static ISetupStep Shortcut()
    {
        var existed = false;
        return new SetupStep("shortcut", c =>
        {
            existed = c.System.Shortcuts.Exists(c.Machine.ShortcutPath);
            c.System.Shortcuts.Create(c.Machine.ShortcutPath, c.Machine.ServiceExe, ServiceDefinition.LaunchVerb, WinPath.Join(c.InstallFolder!, ServiceDefinition.AppExeName));
            c.State = c.State! with { Created = c.State.Created with { Shortcut = c.State.Created.Shortcut || !existed } };
            return StepState.Done;
        }, c =>
        {
            if (!existed) c.System.Shortcuts.Delete(c.Machine.ShortcutPath);
            else if (c.Before?.InstallFolder is { Length: > 0 } old)
                c.System.Shortcuts.Create(c.Machine.ShortcutPath, c.Machine.ServiceExe, ServiceDefinition.LaunchVerb, WinPath.Join(old, ServiceDefinition.AppExeName));
        });
    }

    private static ISetupStep Start() => new SetupStep("start", c =>
    {
        c.System.Registry.DeleteValue("Updating");
        c.System.Service.Start(ServiceWait);
        return StepState.Done;
    }, c => c.System.Service.Stop(ServiceWait));

    /// <summary>Earlier install folders go (one still in use goes at the next restart); then install.json says what this run left.</summary>
    private static ISetupStep Tidy() => new SetupStep("tidy", c =>
    {
        var stale = new List<string>();
        foreach (var folder in c.System.Files.Folders(c.Machine.ProgramFolder))
        {
            if (string.Equals(folder.TrimEnd('\\'), c.InstallFolder!.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) continue;
            if (!c.System.Files.DeleteFolder(folder)) stale.Add(folder);
        }
        c.State = c.State! with { StaleFolders = stale };
        c.System.Files.Write(c.Machine.StateFile, c.State.Encode());
        return StepState.Skipped;
    });

    private static ISetupStep DeleteTrustedFolder(string id, Func<SetupContext, string> folder) => new SetupStep(id, c =>
    {
        var path = folder(c);
        switch (c.System.Files.Check(path))
        {
            case FolderCheck.Missing: return StepState.Skipped;
            case FolderCheck.Planted: throw new SetupException($"{path} wasn't made by Passthrough, so it was left alone.");
            default:
                c.System.Files.DeleteFolder(path);
                return StepState.Done;
        }
    });
}
