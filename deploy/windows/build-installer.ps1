# Build Breeze-Core-Setup.exe.
#
# The version is read from meow_ac/__init__.py rather than typed in, because it
# used to be a hardcoded default in the .nsi ("2.3.0") — so an installer built
# without an explicit /DVERSION would silently claim to be a version it wasn't.
#
#   .\deploy\windows\build-installer.ps1                  # version from source
#   .\deploy\windows\build-installer.ps1 -OutDir C:\out   # put the .exe elsewhere
#
# NOTE: this is the one release artifact CI cannot produce — makensis needs
# Windows. When cutting a release, build it here and attach it by hand.
[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$Makensis = "C:\Program Files (x86)\NSIS\makensis.exe"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $here "..\..")

# --- version, straight from the package ---------------------------------
$initPy = Join-Path $repo "meow_ac\__init__.py"
$m = Select-String -Path $initPy -Pattern '^__version__\s*=\s*"([^"]+)"'
if (-not $m) { throw "could not read __version__ from $initPy" }
$version = $m.Matches[0].Groups[1].Value
Write-Host "version: $version (from meow_ac/__init__.py)"

if (-not (Test-Path $Makensis)) { throw "makensis not found at $Makensis" }

# --- NSSM is fetched, not committed -------------------------------------
$nssm = Join-Path $here "vendor\nssm.exe"
if (-not (Test-Path $nssm)) {
    throw "vendor\nssm.exe missing — run .\deploy\windows\fetch-vendor.ps1 first"
}

& $Makensis "/DVERSION=$version" (Join-Path $here "breeze-core-setup.nsi")
if ($LASTEXITCODE -ne 0) { throw "makensis failed ($LASTEXITCODE)" }

$exe = Join-Path $here "Breeze-Core-Setup.exe"
if (-not (Test-Path $exe)) { throw "makensis reported success but produced no .exe" }

if ($OutDir) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    # Versioned name for hosting alongside other releases; the plain name is
    # kept as the release-asset name it has always had.
    Copy-Item $exe (Join-Path $OutDir "Breeze-Core-Setup-$version.exe") -Force
    Copy-Item $exe (Join-Path $OutDir "Breeze-Core-Setup.exe") -Force
    Write-Host "copied to $OutDir"
}

$sha = (Get-FileHash $exe -Algorithm SHA256).Hash
"{0}  {1} bytes  sha256={2}" -f $exe, (Get-Item $exe).Length, $sha
