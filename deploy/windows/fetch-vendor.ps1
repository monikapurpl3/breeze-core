<#
.SYNOPSIS
    Download the third-party binaries the Windows installer bundles.

.DESCRIPTION
    Fetches NSSM (the public-domain service wrapper) into .\vendor\nssm.exe so
    breeze-core-setup.nsi can embed it. Run once before building the installer.
    The vendor\ dir is git-ignored - binaries are not committed to the repo.

    (Caddy is NOT fetched here: per design, caddy-wizard.ps1 downloads Caddy at
    run time, so the reverse-proxy step stays a separate, optional choice.)
#>
[CmdletBinding()]
param(
    [string]$NssmUrl = 'https://nssm.cc/release/nssm-2.24.zip'
)
$ErrorActionPreference = 'Stop'
$vendor = Join-Path $PSScriptRoot 'vendor'
New-Item -ItemType Directory -Force -Path $vendor | Out-Null

$dest = Join-Path $vendor 'nssm.exe'
if (Test-Path $dest) { Write-Host "nssm.exe already present: $dest"; return }

$zip = Join-Path $env:TEMP ("nssm-{0}.zip" -f ([guid]::NewGuid().ToString('N')))
Write-Host "Downloading NSSM from $NssmUrl"
Invoke-WebRequest -UseBasicParsing -Uri $NssmUrl -OutFile $zip -TimeoutSec 120

Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or [Environment]::Is64BitOperatingSystem) { 'win64' } else { 'win32' }
    $entry = $z.Entries | Where-Object { $_.FullName -match "$arch/nssm\.exe$" } | Select-Object -First 1
    if (-not $entry) { $entry = $z.Entries | Where-Object { $_.FullName -match 'win64/nssm\.exe$' } | Select-Object -First 1 }
    if (-not $entry) { throw "nssm.exe not found in the archive." }
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
} finally { $z.Dispose(); Remove-Item $zip -Force -ErrorAction SilentlyContinue }

Write-Host "Wrote $dest ($((Get-Item $dest).Length) bytes)"
