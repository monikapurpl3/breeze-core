<#
.SYNOPSIS
    Install / uninstall Breeze Core as a hardened Windows background service.

.DESCRIPTION
    Wraps the uvicorn server (meow_ac.app:app) in a Windows service using the
    bundled NSSM. Runs as the low-privilege LOCAL SERVICE account, keeps state
    in %ProgramData%\breeze-core with locked-down ACLs, and (for LAN mode) opens
    only a LocalSubnet firewall rule for the port. This is the Windows analogue
    of the systemd unit in docs/INSTALL.md; see HARDENING.md for the model.

    Called by the NSIS installer, but fully usable on its own.

.EXAMPLE
    # LAN-first (default): bind the detected LAN IP, open a LocalSubnet rule
    powershell -ExecutionPolicy Bypass -File install-service.ps1 -Action Install -InstallDir "C:\Program Files\Breeze Core"

.EXAMPLE
    # Behind Caddy: bind loopback, trust the local proxy, no inbound rule
    powershell -File install-service.ps1 -Action Install -InstallDir "C:\Program Files\Breeze Core" -BehindProxy

.EXAMPLE
    powershell -File install-service.ps1 -Action Uninstall
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Reconfigure')]
    [string]$Action = 'Install',

    [string]$InstallDir = "$env:ProgramFiles\Breeze Core",
    [string]$DataDir    = "$env:ProgramData\breeze-core",
    [string]$ServiceName = 'BreezeCore',

    [string]$BindHost = '',      # empty = auto-detect LAN IP (or 127.0.0.1 with -BehindProxy)
    [int]$Port = 8420,

    [switch]$BehindProxy,        # bind loopback + --proxy-headers + AC_BEHIND_PROXY=1
    [switch]$LockEgress,         # add an outbound "block Internet" rule for the server (best-effort)
    [switch]$NoFirewall,
    [switch]$Purge,              # on uninstall, also delete the data dir (config, tokens, programs)

    [string]$Nssm = ''           # path to nssm.exe; auto-resolved if empty
)

$ErrorActionPreference = 'Stop'
function Info($m)  { Write-Host "[breeze] $m" }
function Warn($m)  { Write-Host "[breeze] WARNING: $m" -ForegroundColor Yellow }
function Die($m)   { Write-Host "[breeze] ERROR: $m" -ForegroundColor Red; exit 1 }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Die "Run this from an elevated (Administrator) PowerShell."
    }
}

function Resolve-Nssm {
    param([string]$Hint)
    $cands = @(
        $Hint,
        (Join-Path $InstallDir 'nssm.exe'),
        (Join-Path $PSScriptRoot 'vendor\nssm.exe'),
        (Join-Path $PSScriptRoot 'nssm.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($cands) { return $cands[0] }
    $cmd = Get-Command nssm.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Die "nssm.exe not found. Pass -Nssm <path>, or run fetch-vendor.ps1 to download it."
}

# Locate a Python >= 3.11 interpreter for building the venv.
function Find-Python {
    $tries = @(
        @('py', '-3.12'), @('py', '-3.11'), @('py', '-3'),
        @('python', ''), @('python3', '')
    )
    foreach ($t in $tries) {
        $exe = $t[0]; $arg = $t[1]
        $cmd = Get-Command $exe -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        try {
            $verArgs = @(); if ($arg) { $verArgs += $arg }
            $verArgs += @('-c', 'import sys;print("%d.%d"%sys.version_info[:2])')
            $v = (& $cmd.Source @verArgs 2>$null | Select-Object -First 1)
            if ($v -match '^(\d+)\.(\d+)$') {
                $maj = [int]$Matches[1]; $min = [int]$Matches[2]
                if ($maj -gt 3 -or ($maj -eq 3 -and $min -ge 11)) {
                    return ,@($cmd.Source, $arg, $v)
                }
            }
        } catch { }
    }
    return $null
}

function Get-LanIPv4 {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -in 'Dhcp','Manual' } |
            Sort-Object -Property SkipAsSource |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    } catch { }
    return '127.0.0.1'
}

# ---------------------------------------------------------------- Uninstall
function Do-Uninstall {
    Assert-Admin
    $nssm = ''
    try { $nssm = Resolve-Nssm $Nssm } catch { }

    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Info "Stopping and removing service '$ServiceName'"
        if ($nssm) {
            & $nssm stop $ServiceName confirm | Out-Null
            & $nssm remove $ServiceName confirm | Out-Null
        } else {
            Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
            sc.exe delete $ServiceName | Out-Null
        }
    } else { Info "Service '$ServiceName' not present" }

    foreach ($rn in @("Breeze Core (LAN)", "Breeze Core egress lockdown")) {
        Get-NetFirewallRule -DisplayName $rn -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    }

    if ($Purge -and (Test-Path $DataDir)) {
        Warn "Purging data dir $DataDir (config, tokens, programs)"
        Remove-Item -Recurse -Force $DataDir
    } else {
        Info "Left data dir intact: $DataDir (use -Purge to remove)"
    }
    Info "Uninstall complete."
}

# ------------------------------------------------------------------ Install
function Do-Install {
    Assert-Admin

    if (-not $BindHost) { $BindHost = if ($BehindProxy) { '127.0.0.1' } else { Get-LanIPv4 } }
    $nssm = Resolve-Nssm $Nssm

    if (-not (Test-Path (Join-Path $InstallDir 'meow_ac'))) {
        Die "meow_ac package not found under $InstallDir. Point -InstallDir at the deployed tree."
    }

    # --- Python + venv -----------------------------------------------------
    $venv = Join-Path $InstallDir 'venv'
    $venvPy = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path $venvPy)) {
        $py = Find-Python
        if (-not $py) {
            Die "Python 3.11+ not found. Install it (winget install Python.Python.3.12 or python.org), then re-run."
        }
        Info "Using Python $($py[2]) at $($py[0]) to build the virtualenv"
        $mkArgs = @(); if ($py[1]) { $mkArgs += $py[1] }
        $mkArgs += @('-m', 'venv', $venv)
        & $py[0] @mkArgs
        if (-not (Test-Path $venvPy)) { Die "venv creation failed." }
    } else { Info "Reusing existing virtualenv at $venv" }

    Info "Installing dependencies (needs internet)"
    & $venvPy -m pip install --upgrade pip --quiet
    & $venvPy -m pip install -r (Join-Path $InstallDir 'requirements.txt') --quiet
    if ($LASTEXITCODE -ne 0) { Die "pip install failed (check your internet connection)." }

    # --- Data dir + hardened ACLs -----------------------------------------
    $logs = Join-Path $DataDir 'logs'
    New-Item -ItemType Directory -Force -Path $DataDir, $logs | Out-Null
    Info "Locking down $DataDir (SYSTEM + Administrators full, LOCAL SERVICE modify)"
    # /inheritance:r drops inherited ACEs - the Windows analogue of chmod 750/600.
    & icacls "$DataDir" /inheritance:r /grant:r `
        "*S-1-5-18:(OI)(CI)F" `
        "*S-1-5-32-544:(OI)(CI)F" `
        "*S-1-5-19:(OI)(CI)M" | Out-Null

    # --- Service via NSSM --------------------------------------------------
    $uvicorn = Join-Path $venv 'Scripts\uvicorn.exe'
    $appArgs = "meow_ac.app:app --host $BindHost --port $Port"
    if ($BehindProxy) { $appArgs += " --proxy-headers --forwarded-allow-ips 127.0.0.1" }

    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Info "Reconfiguring existing service '$ServiceName'"
        & $nssm stop $ServiceName confirm | Out-Null
    } else {
        Info "Registering service '$ServiceName'"
        & $nssm install $ServiceName $uvicorn $appArgs | Out-Null
    }
    & $nssm set $ServiceName Application $uvicorn | Out-Null
    & $nssm set $ServiceName AppParameters $appArgs | Out-Null
    & $nssm set $ServiceName AppDirectory $InstallDir | Out-Null
    & $nssm set $ServiceName DisplayName "Breeze Core" | Out-Null
    & $nssm set $ServiceName Description "Self-hosted, LAN-first control for Midea air conditioners." | Out-Null
    # Low-privilege built-in account (no password, minimal rights).
    & $nssm set $ServiceName ObjectName "NT AUTHORITY\LocalService" "" | Out-Null
    & $nssm set $ServiceName Start SERVICE_AUTO_START | Out-Null
    $envExtra = @(
        "AC_CONFIG=$DataDir\config.json",
        "AC_DEVICES=$DataDir\devices.json",
        "AC_PROGRAMS=$DataDir\programs.json"
    )
    if ($BehindProxy) {
        $envExtra += "AC_BEHIND_PROXY=1"
        $envExtra += "AC_ENROLL_LAN_ONLY=1"
    }
    & $nssm set $ServiceName AppEnvironmentExtra @envExtra | Out-Null
    # Logs + rotation; auto-restart on crash.
    & $nssm set $ServiceName AppStdout (Join-Path $logs 'service.log') | Out-Null
    & $nssm set $ServiceName AppStderr (Join-Path $logs 'service.log') | Out-Null
    & $nssm set $ServiceName AppRotateFiles 1 | Out-Null
    & $nssm set $ServiceName AppRotateBytes 1048576 | Out-Null
    & $nssm set $ServiceName AppExit Default Restart | Out-Null
    & $nssm set $ServiceName AppRestartDelay 5000 | Out-Null

    # --- Firewall ----------------------------------------------------------
    if (-not $NoFirewall) {
        Get-NetFirewallRule -DisplayName "Breeze Core (LAN)" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        if (-not $BehindProxy -and $BindHost -ne '127.0.0.1') {
            Info "Opening inbound TCP $Port from the local subnet only"
            New-NetFirewallRule -DisplayName "Breeze Core (LAN)" -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort $Port -RemoteAddress LocalSubnet -Profile Any | Out-Null
        } else {
            Info "Behind proxy / loopback bind - no inbound rule (Caddy talks to it on 127.0.0.1)"
        }
        if ($LockEgress) {
            # Best-effort egress lockdown: block the server binary from reaching
            # Internet-classified addresses (LAN/Intranet still allowed). See
            # HARDENING.md sec.7 for caveats on Windows network classification.
            Get-NetFirewallRule -DisplayName "Breeze Core egress lockdown" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            New-NetFirewallRule -DisplayName "Breeze Core egress lockdown" -Direction Outbound -Action Block `
                -Program $venvPy -RemoteAddress Internet -Profile Any | Out-Null
            Warn "Egress lockdown added (blocks '$venvPy' to Internet). Verify your units are still reachable."
        }
    }

    # --- Start (only once paired) -----------------------------------------
    if (Test-Path (Join-Path $DataDir 'config.json')) {
        Info "Starting service"
        & $nssm start $ServiceName | Out-Null
        Info "Service '$ServiceName' started, bound to ${BindHost}:$Port"
    } else {
        Warn "No config.json yet - pair your units first, then start the service:"
        Warn "    `"$venvPy`" `"$InstallDir\setup_device.py`"   (with AC_CONFIG=$DataDir\config.json)"
        Warn "    nssm start $ServiceName"
    }

    Info "Done. Manage with: nssm start/stop/restart/edit $ServiceName  |  logs: $logs\service.log"
}

switch ($Action) {
    'Install'     { Do-Install }
    'Reconfigure' { Do-Install }
    'Uninstall'   { Do-Uninstall }
}
