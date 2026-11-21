<#
.SYNOPSIS
  Installs Passthrough's background service from a build, checks every change, turns it off and on, updates it, and
  removes it, checking nothing is left. Changes this PC: run it on the CI runner (elevated) or a test machine.

.PARAMETER Build
  The folder scripts/build-windows.ps1 made.
#>
param([Parameter(Mandatory)] [string]$Build)
$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()
function Check([bool]$ok, [string]$what) { if ($ok) { Write-Host "ok   $what" } else { Write-Host "FAIL $what"; $failures.Add($what) } }
function Verb([string]$exe, [string[]]$arguments) {
    $output = & $exe @arguments 2>&1
    $output | ForEach-Object { Write-Host "     $_" }
    return $LASTEXITCODE
}

$program = Join-Path $env:ProgramFiles 'Passthrough'
$data = Join-Path $env:ProgramData 'Passthrough'
$installed = Join-Path $program 'Passthrough.Service.exe'
$shortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Passthrough.lnk'
$serviceSid = 'S-1-5-80-4278898763-3377807445-3347082863-1725487610-3689323215'

Check ((Verb (Join-Path $Build 'Passthrough.Service.exe') @('--install')) -eq 0) 'install exits 0'
$qc = sc.exe qc PassthroughService | Out-String
Check ($qc -match 'AUTO_START') 'starts automatically'
Check ($qc -match [regex]::Escape("`"$installed`" --service")) 'runs the exe whose path never changes'
Check ($qc -match 'NT SERVICE\\PassthroughService') 'runs as its virtual account'
Check ((sc.exe qsidtype PassthroughService | Out-String) -match 'RESTRICTED') 'restricted service SID'
$privileges = sc.exe qprivs PassthroughService | Out-String
Check ($privileges -match 'SeChangeNotifyPrivilege' -and $privileges -notmatch 'SeImpersonatePrivilege') 'only the change-notify privilege'
Check ((sc.exe qfailure PassthroughService | Out-String) -match 'RESTART') 'restarts after a crash'
Check ((Get-Service PassthroughService).Status -eq 'Running') 'running'
$security = (sc.exe sdshow PassthroughService | Out-String).Trim()
Check ($security -match '\(A;;CCLCSWLORC;;;IU\)') 'interactive users can query only'
Check ((Get-Acl $data).Owner -match 'Administrators') 'data folder owned by Administrators'
Check ((Get-Acl (Join-Path $data 'store')).Sddl -match $serviceSid) 'the store names the service'
$state = Get-Content (Join-Path $data 'install.json') -Raw | ConvertFrom-Json
Check (Test-Path (Join-Path $state.installFolder 'Passthrough.exe')) 'the app is in its install folder'
Check ((Get-ItemProperty 'HKLM:\SOFTWARE\Passthrough').Enabled -eq 1) 'Enabled=1'
Check (Test-Path $shortcut) 'Start menu shortcut'
$rules = @(Get-NetFirewallRule -Group 'Passthrough' -ErrorAction SilentlyContinue)
Check ($rules.Count -ge 2) "firewall rules ($($rules.Count))"
Check ((Get-Content (Join-Path $data 'logs\service.log') -Raw -ErrorAction SilentlyContinue) -match 'service: started') 'the service logged its start'

Check ((Verb $installed @('--off')) -eq 0) 'off exits 0'
Check ((Get-Service PassthroughService).Status -eq 'Stopped') 'stopped'
Check ((Get-ItemProperty 'HKLM:\SOFTWARE\Passthrough').Enabled -eq 0) 'Enabled=0'
Check (@(Get-NetFirewallRule -Group 'Passthrough' | Where-Object Enabled -eq 'True').Count -eq 0) 'rules off'

Check ((Verb (Join-Path $Build 'Passthrough.Service.exe') @('--install')) -eq 0) 'install again (on) exits 0'
Check ((Get-Service PassthroughService).Status -eq 'Running') 'running again'
$second = (Get-Content (Join-Path $data 'install.json') -Raw | ConvertFrom-Json).installFolder
Check ($second -ne $state.installFolder -and -not (Test-Path $state.installFolder)) 'a fresh folder, the old one gone'

Check ((Verb (Join-Path $Build 'Passthrough.Service.exe') @('--update')) -eq 0) 'update exits 0'
Check ((Verb (Join-Path $Build 'Passthrough.Service.exe') @('--remove')) -ne 0) 'remove refuses to run from the build'
Check ((Verb $installed @('--remove')) -eq 0) 'remove exits 0'
Check ($null -eq (Get-Service PassthroughService -ErrorAction SilentlyContinue)) 'no service'
Check (@(Get-NetFirewallRule -Group 'Passthrough' -ErrorAction SilentlyContinue).Count -eq 0) 'no rules'
Check (-not (Test-Path 'HKLM:\SOFTWARE\Passthrough')) 'no registry key'
Check (-not (Test-Path $data)) 'no data folder'
Check (-not (Test-Path $shortcut)) 'no shortcut'
Check (-not (Test-Path 'C:\Windows\ServiceProfiles\PassthroughService')) 'no service profile'
# The running exe can't delete itself: what is left of Program Files\Passthrough goes at the next restart.
Check (-not (Test-Path $program) -or @(Get-ChildItem $program -Recurse -File).Count -le 1) 'program folder gone or queued'

if ($failures.Count) { throw "$($failures.Count) check(s) failed: $($failures -join '; ')" }
Write-Host 'Install round trip passed.'
