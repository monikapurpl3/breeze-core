# Windows deployment files

Scripts + installer for running Breeze Core on Windows. Full guide:
**[https://github.com/monikapurpl3/breeze-core/wiki/Installing-on-Windows](https://github.com/monikapurpl3/breeze-core/wiki/Installing-on-Windows)**.

| File | What it is |
|---|---|
| `breeze-core-setup.nsi` | NSIS guided installer (compile → `Breeze-Core-Setup.exe`). Server is required; Caddy reverse-proxy setup is a separate, optional component. |
| `install-service.ps1` | Build the venv + register/unregister the hardened `BreezeCore` service (bundled NSSM, `LOCAL SERVICE`, LAN firewall, locked-down `%ProgramData%\breeze-core`). |
| `caddy-wizard.ps1` | Guided Caddy reverse proxy: downloads Caddy, writes a hardened Caddyfile (auto-HTTPS, headers, real-client XFF, LAN-only admin), registers it as a service. Supports `-DryRun`. |
| `breeze-tripwire.ps1` | fail2ban-style watcher: tails Caddy's access log and bans abusive IPs via Windows Firewall (LAN never banned; bans expire). Runs as the `BreezeTripwire` service. |
| `Caddyfile.example` | Static reference of the hardened Caddyfile the wizard renders. |
| `pair.cmd` | Convenience: run unit discovery/pairing with `AC_CONFIG` preset. |
| `fetch-vendor.ps1` | Downloads NSSM into `vendor\` for bundling (git-ignored; not committed). |
| `build-installer.ps1` | Builds `Breeze-Core-Setup.exe`, taking the version from `meow_ac/__init__.py` rather than a hand-typed `/DVERSION`. |

## Build the installer

From the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\windows\fetch-vendor.ps1
.\deploy\windows\build-installer.ps1
```

`build-installer.ps1` reads the version from `meow_ac/__init__.py` and passes
it to `makensis`, so the installer can't claim a version the package doesn't
have — it used to be typed by hand here, which is exactly how the shipped
installer ended up stamped `2.3.0` while the package was on 3.x. `-OutDir <dir>`
also drops a versioned copy; the SHA256 is printed either way.

**This is the one release artifact CI can't build** — `makensis` needs Windows.
Build it here at release time, attach it to the tag, and pass it to
`packaging/repo/build-bsd-repo.sh` as `WINDOWS_EXE=<path>` so the package host
gets it too.

All scripts are ASCII / BOM-free so Windows PowerShell 5.1 and PowerShell 7+ both
parse them. Run the elevated steps from an Administrator PowerShell.
