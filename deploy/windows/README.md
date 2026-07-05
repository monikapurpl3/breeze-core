# Windows deployment files

Scripts + installer for running Breeze Core on Windows. Full guide:
**[../../docs/WINDOWS.md](../../docs/WINDOWS.md)**.

| File | What it is |
|---|---|
| `breeze-core-setup.nsi` | NSIS guided installer (compile → `Breeze-Core-Setup.exe`). Server is required; Caddy reverse-proxy setup is a separate, optional component. |
| `install-service.ps1` | Build the venv + register/unregister the hardened `BreezeCore` service (bundled NSSM, `LOCAL SERVICE`, LAN firewall, locked-down `%ProgramData%\breeze-core`). |
| `caddy-wizard.ps1` | Guided Caddy reverse proxy: downloads Caddy, writes a hardened Caddyfile (auto-HTTPS, headers, real-client XFF, LAN-only admin), registers it as a service. Supports `-DryRun`. |
| `breeze-tripwire.ps1` | fail2ban-style watcher: tails Caddy's access log and bans abusive IPs via Windows Firewall (LAN never banned; bans expire). Runs as the `BreezeTripwire` service. |
| `Caddyfile.example` | Static reference of the hardened Caddyfile the wizard renders. |
| `pair.cmd` | Convenience: run unit discovery/pairing with `AC_CONFIG` preset. |
| `fetch-vendor.ps1` | Downloads NSSM into `vendor\` for bundling (git-ignored; not committed). |

## Build the installer

```powershell
powershell -ExecutionPolicy Bypass -File .\fetch-vendor.ps1
& "C:\Program Files (x86)\NSIS\makensis.exe" /DVERSION=2.3.0 breeze-core-setup.nsi
```

All scripts are ASCII / BOM-free so Windows PowerShell 5.1 and PowerShell 7+ both
parse them. Run the elevated steps from an Administrator PowerShell.
