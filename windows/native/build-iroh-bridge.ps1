# Builds passthrough_iroh.dll (windows/native/iroh-bridge) with the toolchain and dependencies its
# rust-toolchain.toml and Cargo.lock pin. Needs rustup (https://rustup.rs) and the MSVC build tools.
# The .NET build copies the result beside the app and the tests.
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot 'iroh-bridge'
$cargo = (Get-Command cargo -ErrorAction SilentlyContinue)?.Source
if (-not $cargo) { $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
if (-not (Test-Path $cargo)) { throw 'cargo was not found: install Rust with rustup (https://rustup.rs) first.' }
Push-Location $bridge
try {
    & $cargo build --release --locked
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
Write-Host "Built $(Join-Path $bridge 'target\release\passthrough_iroh.dll')"
