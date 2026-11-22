<#
.SYNOPSIS
  Passthrough for Windows in one command: check, get what's missing, build, install, update, reinstall, turn off, remove.

.DESCRIPTION
  scripts/windows.ps1 <verb> [flags]

    doctor     What's missing or wrong. Changes nothing.
    deps       Installs what's missing (the .NET 10 SDK, Rust, the MSVC build tools), asking first unless -Yes.
    build      Builds the self-contained folder (scripts/build-windows.ps1) into -Output.
    install    Builds, then sets up Remote access's background service behind one administrator prompt, turns on
               Start at login and starts the tray app. -Screen also sets up the screen (Remote Desktop, kept closed to
               the network) in the same prompt.
    update     Builds (after `git pull --ff-only` with -Pull), updates the service behind one prompt, then restarts the
               tray app so it runs the new build too. Phones keep their access.
    reinstall  Installs over the current install, which repairs it and keeps the phones' access. -Clean removes
               everything first; then every phone must be plugged in again.
    off        Turns Remote access off: phones can't reach this PC until it's turned on again. The tray app stays for
               the cable.
    remove     Removes the service, its folders, its firewall rules and what it changed in Remote Desktop, stops the tray
               app and removes Start at login. -Purge also deletes this account's Passthrough settings, pairings and
               shell history.

  Flags: -Yes (don't ask), -WhatIf (say what would happen, do nothing), -Pull, -Screen, -Clean, -Purge,
  -Force (build or install from a folder other accounts can change), -Output <folder> (default
  %LOCALAPPDATA%\PassthroughBuild, which only you can change).

  Exits 0 when it worked; otherwise prints one sentence saying what failed and exits 1.
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('doctor', 'deps', 'build', 'install', 'update', 'reinstall', 'off', 'remove')]
    [string]$Verb = 'doctor',
    [switch]$Yes,
    [switch]$WhatIf,
    [switch]$Pull,
    [switch]$Screen,
    [switch]$Clean,
    [switch]$Purge,
    [switch]$Force,
    [string]$Output = (Join-Path $env:LOCALAPPDATA 'PassthroughBuild')
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# Resolved once, as PowerShell resolves it: the folder checked is the folder built and run from.
$Output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
$ProgramRoot = Join-Path $env:ProgramFiles 'Passthrough'
$Launcher = Join-Path $ProgramRoot 'Passthrough.Service.exe'
$SetupLog = Join-Path $env:ProgramData 'Passthrough\logs\setup.log'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# MARK: Saying things

function Say([string]$text) { Write-Host $text }
function Step([string]$text) { Write-Host "-> $text" -ForegroundColor Cyan }
function Good([string]$text) { Write-Host "   ok    $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "   needs $text" -ForegroundColor Yellow }
function Fail([string]$sentence) {
    Write-Host "windows.ps1 $Verb`: $sentence" -ForegroundColor Red
    exit 1
}
function Ask([string]$question) {
    if ($Yes) { return $true }
    $answer = Read-Host "$question [y/N]"
    return $answer -match '^(y|yes)$'
}

# MARK: What is on this PC

function Find-Dotnet {
    $candidates = @(
        (Get-Command dotnet -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),
        (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($dotnet in $candidates) {
        $sdks = & $dotnet --list-sdks 2>$null
        if ($sdks -match '^10\.') { return $dotnet }
    }
    return $null
}

function Find-Cargo {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
    if (-not $cargo) { $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
    if (Test-Path $cargo) { return $cargo }
    return $null
}

function Test-MsvcTools {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $false }
    $found = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    return [bool]$found
}

function Get-Installed {
    $key = Get-ItemProperty 'HKLM:\SOFTWARE\Passthrough' -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    [pscustomobject]@{ Build = $key.Build; Folder = $key.InstallFolder; Enabled = $key.Enabled -eq 1 }
}

function Get-TrayProcesses {
    # This session's tray apps only: another account's Passthrough is never touched.
    $session = (Get-Process -Id $PID).SessionId
    Get-Process -Name Passthrough -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }
}

<#
  Who besides you, the administrators and SYSTEM can change a folder or any folder above it (S1 in the security
  review): setup copies the build into Program Files behind your administrator prompt, so whoever can change the build
  (or the source it is built from, or rename a folder above either) can run code as administrator.
#>
function Get-OtherWriters([string]$path) {
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', $me,
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464') # SYSTEM, Administrators, CREATOR OWNER, you, TrustedInstaller
    # In the folder itself anything that writes counts; above it, only what could rename or replace the way down to it.
    # GENERIC_ALL (0x10000000) and GENERIC_WRITE (0x40000000) as stored, often on inheritable rules, count as what they mean.
    $writeRights = [int][System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership' -bor 0x50000000
    $replaceRights = [int][System.Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership' -bor 0x10000000
    $inherits = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $target = $true
    $found = [System.Collections.Generic.List[string]]::new()
    $dir = [System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($path))
    while ($dir) {
        if ($dir.Exists) {
            $acl = Get-Acl -LiteralPath $dir.FullName
            # Whoever owns a folder can rewrite its permissions.
            $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            if ($trusted -notcontains $owner) {
                try { $name = ([System.Security.Principal.SecurityIdentifier]$owner).Translate([System.Security.Principal.NTAccount]).Value } catch { $name = $owner }
                $found.Add("$name owns $($dir.FullName)")
            }
            foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
                if ($rule.AccessControlType -ne 'Allow') { continue }
                # An inherit-only rule gives nothing on this folder but everything on what is made inside it: in the
                # folder itself (the build is made there) that counts; above it, it reaches down as an inherited rule.
                if ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) {
                    if (-not $target -or ($rule.InheritanceFlags -band $inherits) -eq 0) { continue }
                }
                if (([int]$rule.FileSystemRights -band $(if ($target) { $writeRights } else { $replaceRights })) -eq 0) { continue }
                $sid = $rule.IdentityReference.Value
                if ($trusted -contains $sid) { continue }
                try { $name = ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value } catch { $name = $sid }
                $found.Add("$name on $($dir.FullName)")
            }
            # A folder not made yet inherits from the first one that exists: that one counts as the folder itself.
            $target = $false
        }
        $dir = $dir.Parent
    }
    return ,$found
}

function Assert-OnlyYouCanWrite([string]$what, [string]$path) {
    $others = Get-OtherWriters $path
    if ($others.Count -eq 0) { return }
    $first = $others[0]
    if ($Force) {
        Warn "$what can be changed by others ($first); going on because of -Force"
        return
    }
    Fail ("$what can be changed by other accounts on this PC ($first), so the administrator prompt could install their code. " +
        "Keep the source under your profile (for example git clone into $env:USERPROFILE\src\passthrough) and build into $env:LOCALAPPDATA\PassthroughBuild, or pass -Force if you're the only one using this PC.")
}

# MARK: Doing things

function Invoke-Elevated([string]$exe, [string[]]$arguments, [string]$what) {
    if ($WhatIf) { Say "   would run, as administrator: `"$exe`" $($arguments -join ' ')"; return }
    if (-not (Test-Path -LiteralPath $exe)) { Fail "$exe is missing, so nothing was changed." }
    Step "$what (Windows asks for an administrator)"
    try {
        $process = Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    }
    catch {
        # ERROR_CANCELLED (1223) is the prompt declined; anything else is said as it is.
        $native = $_.Exception.InnerException ?? $_.Exception
        if ($native -is [System.ComponentModel.Win32Exception] -and $native.NativeErrorCode -eq 1223) { Fail "The administrator prompt was declined, so nothing was changed." }
        Fail "Windows couldn't start $exe as administrator: $($_.Exception.Message)"
    }
    $result = Get-Content $SetupLog -Tail 50 -ErrorAction SilentlyContinue | Where-Object { $_ -match '"result"' } | Select-Object -Last 1
    if ($process.ExitCode -ne 0) {
        $said = if ($result -match '"error":"([^"]*)"') { $Matches[1] } else { "it stopped with code $($process.ExitCode); see $SetupLog" }
        Fail "$what didn't finish: $said"
    }
    Good $what
}

function Invoke-Build {
    if (-not (Find-Dotnet)) { Fail 'The .NET 10 SDK is missing. Run: scripts/windows.ps1 deps' }
    if (-not (Find-Cargo)) { Fail 'Rust is missing. Run: scripts/windows.ps1 deps' }
    # The build replaces the folder: only one it made before (files.json) or an empty one may be used, never, say, Documents.
    if ((Test-Path -LiteralPath $Output) -and -not (Test-Path -LiteralPath (Join-Path $Output 'files.json')) -and
        (Get-ChildItem -LiteralPath $Output -Force | Select-Object -First 1)) {
        Fail "$Output already holds other files, and building there would delete them. Pick an empty or new folder for -Output."
    }
    Assert-OnlyYouCanWrite 'The source folder' $Root
    Assert-OnlyYouCanWrite 'The build folder' $Output
    if ($WhatIf) { Say "   would build $Root into $Output"; return }
    Step "Building into $Output"
    $dotnet = Find-Dotnet
    $env:PATH = "$(Split-Path $dotnet);$(Split-Path (Find-Cargo));$env:PATH"
    New-Item -ItemType Directory -Force $Output | Out-Null
    # The bundle build's publish rewrites two lock files for win-x64; they are put back only if nobody had changed them.
    $locks = @('windows/src/Passthrough.Core/packages.lock.json', 'windows/src/Passthrough.Windows/packages.lock.json')
    git -C $Root diff --quiet -- @locks 2>$null
    $locksClean = $LASTEXITCODE -eq 0
    try { & (Join-Path $Root 'scripts\build-windows.ps1') -Output $Output }
    catch { Fail "The build failed: $($_.Exception.Message) The errors are above." }
    if ($locksClean) { git -C $Root checkout -- @locks 2>$null }
    else { Warn 'The two packages.lock.json files had your own changes, so the build''s rewrite of them is left for you to check.' }
    Good "Built $((Get-Content (Join-Path $Output 'files.json') -Raw | ConvertFrom-Json).build)"
}

function Stop-Tray {
    $tray = @(Get-TrayProcesses)
    if ($tray.Count -eq 0) { return }
    if ($WhatIf) { Say "   would quit the tray app (its phones' shells end)"; return }
    Step 'Quitting the tray app (phones'' shells on this PC end)'
    $tray | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 3
    Get-TrayProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    Good 'The tray app quit'
}

function Start-Tray {
    if ($WhatIf) { Say '   would start the installed tray app'; return }
    if (-not (Test-Path $Launcher)) { Fail "There's no installed copy to start ($Launcher is missing)." }
    Step 'Starting the tray app'
    Start-Process -FilePath $Launcher -ArgumentList '--launch'
    Good 'The tray app is starting from the installed copy'
}

function Set-StartAtLogin([bool]$on) {
    if ($WhatIf) { Say "   would turn Start at login $(if ($on) { 'on' } else { 'off' })"; return }
    if ($on) { Set-ItemProperty -Path $RunKey -Name Passthrough -Value "`"$Launcher`" --launch" }
    else { Remove-ItemProperty -Path $RunKey -Name Passthrough -ErrorAction SilentlyContinue }
}

# MARK: The verbs

function Invoke-Doctor {
    $problems = 0
    Step 'This PC'
    $os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$os.CurrentBuildNumber
    $name = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    if ($build -lt 17763) { Warn "$name build ${build}: Passthrough needs Windows 10 1809 or later"; $problems++ }
    else { Good "$name $($os.DisplayVersion) (build $build), $($os.EditionID)" }
    if ($build -lt 22000) { Warn 'Windows 10 has no TLS 1.3 server: phones reach this PC through iroh only' }
    if ($os.EditionID -match '^Core') { Warn 'Windows Home has no Remote Desktop: the shell works, the screen needs Windows Pro' }

    Step 'Building'
    if (Find-Dotnet) { Good ".NET 10 SDK ($(Find-Dotnet))" } else { Warn '.NET 10 SDK: run scripts/windows.ps1 deps'; $problems++ }
    if (Find-Cargo) { Good "Rust ($(Find-Cargo))" } else { Warn 'Rust: run scripts/windows.ps1 deps'; $problems++ }
    if (Test-MsvcTools) { Good 'MSVC build tools' } else { Warn 'MSVC build tools (Rust needs them): run scripts/windows.ps1 deps'; $problems++ }
    foreach ($check in @(@('The source folder', $Root), @('The build folder', $Output))) {
        $others = Get-OtherWriters $check[1]
        if ($others.Count -eq 0) { Good "$($check[0]) can only be changed by you and administrators ($($check[1]))" }
        else { Warn "$($check[0]) can be changed by other accounts: $($others[0]). Install refuses it without -Force"; $problems++ }
    }

    Step 'Installed'
    $installed = Get-Installed
    if (-not $installed) { Warn 'Remote access is not set up on this PC: scripts/windows.ps1 install' }
    else {
        Good "Build $($installed.Build) in $($installed.Folder)"
        $service = Get-Service PassthroughService -ErrorAction SilentlyContinue
        if (-not $installed.Enabled) { Warn 'Remote access is off' }
        elseif ($service.Status -ne 'Running') { Warn "The background service is $($service.Status)"; $problems++ }
        else { Good 'The background service is running' }
        $tray = @(Get-TrayProcesses)
        if ($tray.Count -eq 0) { Warn 'The tray app isn''t running: open Passthrough from the Start menu' }
        elseif ($tray[0].Path -notlike "$($installed.Folder)*") { Warn "The tray app runs another build ($($tray[0].Path)): quit it and open it from the Start menu, or run update" }
        else { Good 'The tray app runs the installed build' }
        $run = (Get-ItemProperty $RunKey -Name Passthrough -ErrorAction SilentlyContinue).Passthrough
        if ($run) { Good 'Start at login is on' } else { Warn 'Start at login is off (Settings ▸ General)' }
    }

    Step 'Screen (Remote Desktop)'
    $denied = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    $blocks = @(Get-NetFirewallRule -DisplayName 'Passthrough: keep Remote Desktop closed*' -ErrorAction SilentlyContinue | Where-Object Enabled -eq 'True')
    if ($denied -eq 1) { Warn 'Remote Desktop is off: Settings ▸ Remote access ▸ Screen ▸ Set up… (or install -Screen)' }
    elseif ($blocks.Count -ge 2) { Good 'Remote Desktop is on, kept closed to the network by Passthrough''s block rules' }
    else { Warn 'Remote Desktop is on without Passthrough''s block rules: Settings ▸ Remote access shows whether it is open to the network' }

    Step 'Phones on the cable'
    if ((Get-AppxPackage -Name 'AppleInc.AppleDevices' -ErrorAction SilentlyContinue) -or (Get-Service 'Apple Mobile Device Service' -ErrorAction SilentlyContinue)) { Good 'Apple Devices (for iPhones)' }
    else { Warn 'Apple Devices isn''t installed: iPhones need it (Microsoft Store)' }
    $adb = @((Get-Command adb -ErrorAction SilentlyContinue).Source, (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe')) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($adb) { Good "adb (for Android phones): $adb" } else { Say '   --    adb isn''t installed; only Android phones need it' }

    Say ''
    if ($problems -eq 0) { Say 'Nothing is missing.' } else { Say "$problems thing(s) need attention; see above." }
}

function Invoke-Deps {
    $wanted = @()
    if (-not (Find-Dotnet)) { $wanted += , @('the .NET 10 SDK', { winget install --id Microsoft.DotNet.SDK.10 --exact --accept-source-agreements --accept-package-agreements }) }
    if (-not (Test-MsvcTools)) {
        $wanted += , @('the MSVC build tools (Visual Studio Build Tools with the C++ workload, a few GB)', {
            winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --accept-source-agreements --accept-package-agreements `
                --override '--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --wait' })
    }
    if (-not (Find-Cargo)) { $wanted += , @('Rust (rustup)', { winget install --id Rustlang.Rustup --exact --accept-source-agreements --accept-package-agreements }) }
    if ($wanted.Count -eq 0) { Say 'Nothing to install: the .NET 10 SDK, Rust and the MSVC build tools are here.'; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Fail 'winget is missing; install App Installer from the Microsoft Store, then run this again.' }
    foreach ($item in $wanted) {
        if ($WhatIf) { Say "   would install $($item[0]) with winget"; continue }
        if (-not (Ask "Install $($item[0]) with winget?")) { Say "   skipped $($item[0])"; continue }
        Step "Installing $($item[0])"
        & $item[1]
        if ($LASTEXITCODE -ne 0) { Fail "Installing $($item[0]) failed (winget exit code $LASTEXITCODE)." }
        Good $item[0]
    }
    if (-not $WhatIf -and (Find-Cargo)) {
        # The compiler the iroh bridge pins (rust-toolchain.toml), installed the first time cargo runs there.
        Push-Location (Join-Path $Root 'windows\native\iroh-bridge')
        try { & (Find-Cargo) --version | Out-Null } finally { Pop-Location }
    }
    Say 'Open a new terminal if a command above was just installed, so PATH has it.'
}

<#
  The elevated setup allows the account that is asking. Run from here it can only tell who approved the prompt, so a
  standard account approving with an administrator's password would set it up for the administrator instead: that
  account turns Remote access on in the tray app (Settings ▸ Remote access), which tells setup who asked.
#>
function Assert-AdministratorAccount {
    $claims = [System.Security.Principal.WindowsIdentity]::GetCurrent().Claims
    if ($claims | Where-Object { $_.Value -eq 'S-1-5-32-544' }) { return }
    Fail ('Your Windows account isn''t an administrator, so setup run from here would be set up for whoever approves the prompt. ' +
        'Build with: scripts/windows.ps1 build, then open the built Passthrough.exe and choose Settings ▸ Remote access ▸ Turn on.')
}

<#
  The build replaces its folder, which then takes its permissions from the folder above it: checked again just before
  setup runs the exe from it as administrator.
#>
function Assert-BuildStillYours {
    if ($WhatIf) { return }
    Assert-OnlyYouCanWrite 'The build' $Output
}

function Invoke-Install([bool]$built = $false) {
    Assert-AdministratorAccount
    if (Get-Installed) { Say 'Remote access is already set up here; installing again repairs it and keeps the phones'' access.' }
    if (-not $built) { Invoke-Build }
    Assert-BuildStillYours
    $arguments = @('--install')
    if ($Screen) { $arguments += '--screen' }
    Invoke-Elevated (Join-Path $Output 'Passthrough.Service.exe') $arguments $(if ($Screen) { 'Setting up Remote access and the screen' } else { 'Setting up Remote access' })
    Stop-Tray
    Set-StartAtLogin $true
    Start-Tray
    if ($WhatIf) { return }
    Say ''
    Say 'Next: plug each phone in once and pair it with the code shown in the tray''s flyout. It then gets the shell; tick Screen for it in Settings ▸ Remote access to let it see the screen.'
}

function Invoke-Update {
    if (-not (Get-Installed)) { Fail 'There''s nothing to update: Remote access isn''t set up here. Run: scripts/windows.ps1 install' }
    Assert-AdministratorAccount
    if ($Pull) {
        if ($WhatIf) { Say "   would run git pull --ff-only in $Root" }
        else {
            Step 'Pulling'
            git -C $Root pull --ff-only
            if ($LASTEXITCODE -ne 0) { Fail 'git pull --ff-only failed (local changes, or the branch moved): nothing was built.' }
        }
    }
    Invoke-Build
    Assert-BuildStillYours
    Invoke-Elevated (Join-Path $Output 'Passthrough.Service.exe') @('--update') 'Updating the background service'
    Stop-Tray
    Start-Tray
    if (-not $WhatIf) { Say ''; Say "Updated to $((Get-Installed).Build). Phones keep their access; they reconnect by themselves." }
}

function Invoke-Remove([bool]$purge) {
    if (-not (Get-Installed) -and -not (Test-Path $Launcher)) { Say 'Remote access isn''t set up here; nothing to remove from Windows.' }
    else {
        if (-not $WhatIf -and -not (Ask 'Remove Passthrough''s service? Every phone loses its access to this PC.')) { Fail 'Nothing was removed.' }
        Stop-Tray
        Invoke-Elevated $Launcher @('--remove') 'Removing the background service'
    }
    Stop-Tray
    Set-StartAtLogin $false
    if ($purge) {
        $data = Join-Path $env:LOCALAPPDATA 'Passthrough'
        if ($WhatIf) { Say "   would delete $data (settings, cable pairings, shell history)" }
        elseif (Test-Path $data) {
            if (-not (Ask "Also delete $data? Every phone must pair again.")) { Say '   kept your settings and pairings' }
            else { Remove-Item -Recurse -Force $data; Good "Deleted $data" }
        }
    }
}

Say "Passthrough for Windows: $Verb$(if ($WhatIf) { ' (what if: nothing changes)' })"
switch ($Verb) {
    'doctor' { Invoke-Doctor }
    'deps' { Invoke-Deps }
    'build' { Invoke-Build }
    'install' { Invoke-Install }
    'update' { Invoke-Update }
    'reinstall' {
        if ($Clean) {
            Say 'A clean reinstall removes everything first: every phone must be plugged in again afterwards.'
            # Built first: a build that fails (or is refused) leaves the current install as it was.
            Invoke-Build
            Invoke-Remove $false
            Invoke-Install $true
        }
        else {
            Say 'Reinstalling over the current install: it is repaired, and the phones keep their access.'
            Invoke-Install
        }
    }
    'off' {
        if (-not (Get-Installed)) { Fail 'Remote access isn''t set up here.' }
        Invoke-Elevated $Launcher @('--off') 'Turning Remote access off'
        Say 'Phones can''t reach this PC now. The tray app stays for phones on the cable; turn Remote access on again in Settings.'
    }
    'remove' { Invoke-Remove $Purge.IsPresent }
}
exit 0
