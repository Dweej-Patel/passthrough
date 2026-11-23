<#
.SYNOPSIS
  Builds Passthrough for Windows as one self-contained folder, ready for Remote access's background service.

.DESCRIPTION
  Publishes the tray app self-contained for win-x64 and the service as one self-contained file beside it, with the
  iroh bridge, into windows/artifacts/Passthrough, and writes files.json there: every file's path, size and SHA-256.
  Turning Remote access on copies exactly those files into Program Files, after checking each hash.

  A service account can't use a .NET that lives in one user's profile, so a framework-dependent build can't be
  installed: build with this script, then run windows/artifacts/Passthrough/Passthrough.exe and turn Remote access on.
#>
#Requires -Version 7.2
param(
    [string]$Output = (Join-Path $PSScriptRoot '..\windows\artifacts\Passthrough'),
    [string]$Configuration = 'Release'
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$windows = Join-Path $root 'windows'

$bridge = Join-Path $windows 'native\iroh-bridge\target\release\passthrough_iroh.dll'
if (-not (Test-Path $bridge)) {
    & (Join-Path $windows 'native\build-iroh-bridge.ps1')
    if (-not (Test-Path $bridge)) { throw 'The iroh bridge did not build.' }
}

# The build's name: when it was built (newer always compares higher, so an older copy can't downgrade an install) and
# the commit.
$commit = (git -C $root rev-parse --short HEAD).Trim()
$build = '{0}+{1}' -f (Get-Date).ToUniversalTime().ToString('yyyy.M.d.HHmm'), $commit

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('passthrough-build-' + [guid]::NewGuid().ToString('N'))
try {
    # Its own build folders, so a copy of the app running from bin never blocks the build.
    $app = Join-Path $staging 'app'
    $service = Join-Path $staging 'service'
    $artifacts = Join-Path $staging 'build'
    dotnet publish (Join-Path $windows 'src\Passthrough.App') -c $Configuration -r win-x64 --self-contained -o $app --artifacts-path $artifacts "-p:InformationalVersion=$build"
    if ($LASTEXITCODE -ne 0) { throw 'The app did not build.' }
    dotnet publish (Join-Path $windows 'src\Passthrough.Service') -c $Configuration -r win-x64 --self-contained -p:PublishSingleFile=true -o $service --artifacts-path $artifacts "-p:InformationalVersion=$build"
    if ($LASTEXITCODE -ne 0) { throw 'The service did not build.' }
    $term = Join-Path $staging 'term'
    dotnet publish (Join-Path $windows 'src\Passthrough.Term') -c $Configuration -r win-x64 --self-contained -p:PublishSingleFile=true -o $term --artifacts-path $artifacts "-p:InformationalVersion=$build"
    if ($LASTEXITCODE -ne 0) { throw 'The terminal did not build.' }

    if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
    New-Item -ItemType Directory -Force $Output | Out-Null
    Copy-Item -Recurse (Join-Path $app '*') $Output
    Copy-Item (Join-Path $service 'Passthrough.Service.exe') $Output
    Copy-Item (Join-Path $term 'passthrough-term.exe') $Output
    Get-ChildItem $Output -Recurse -Filter *.pdb | Remove-Item

    $full = (Resolve-Path $Output).Path.TrimEnd('\') + '\'
    $files = Get-ChildItem $Output -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path   = $_.FullName.Substring($full.Length)
            size   = $_.Length
            sha256 = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant()
        }
    }
    $manifest = [ordered]@{ build = $build; files = @($files) }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM (Join-Path $Output 'files.json')
    $size = ($files | ForEach-Object { $_.size } | Measure-Object -Sum).Sum / 1MB
    Write-Host ('Built {0}: {1} files, {2:N0} MB, in {3}' -f $build, $files.Count, $size, (Resolve-Path $Output))
}
finally {
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
}
