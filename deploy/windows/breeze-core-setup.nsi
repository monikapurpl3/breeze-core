; Breeze Core — Windows guided installer (NSIS).
;
; Installs the app tree + bundled NSSM, builds a Python venv, and registers the
; hardened "BreezeCore" Windows service (see install-service.ps1). The Caddy
; reverse-proxy setup is a SEPARATE, optional component — the server installs
; and runs LAN-first without it; add Caddy only if exposing it publicly.
;
; Build:
;   powershell -ExecutionPolicy Bypass -File fetch-vendor.ps1   (gets vendor\nssm.exe)
;   "C:\Program Files (x86)\NSIS\makensis.exe" breeze-core-setup.nsi
; Output: Breeze-Core-Setup.exe

Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

!ifndef VERSION
  !define VERSION "2.3.0"
!endif

Name "Breeze Core ${VERSION}"
OutFile "Breeze-Core-Setup.exe"
InstallDir "$PROGRAMFILES64\Breeze Core"
InstallDirRegKey HKLM "Software\BreezeCore" "InstallDir"
RequestExecutionLevel admin
ShowInstDetails show
ShowUnInstDetails show

Var RunWizard
Var PS

; ----- MUI -----
!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_UNICON "${NSISDIR}\Contrib\Graphics\Icons\modern-uninstall.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\..\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES

; Finish page: two optional next steps.
!define MUI_FINISHPAGE_RUN "$INSTDIR\pair.cmd"
!define MUI_FINISHPAGE_RUN_TEXT "Pair my AC units now (prints the API key once)"
!define MUI_FINISHPAGE_SHOWREADME ""
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Set up the Caddy reverse proxy now (for public HTTPS)"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION RunCaddyWizard
!define MUI_FINISHPAGE_LINK "Breeze Core on GitHub"
!define MUI_FINISHPAGE_LINK_LOCATION "https://github.com/monikapurpl3/breeze-core"
!define MUI_PAGE_CUSTOMFUNCTION_SHOW finishShow
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ---------------------------------------------------------------- Sections
Section "Breeze Core server (Windows service)" SEC_SERVER
  SectionIn RO
  SetOutPath "$INSTDIR"

  ; App tree (skip caches).
  File /r /x "__pycache__" /x "*.pyc" "..\..\meow_ac"
  File /r "..\..\static"
  File "..\..\setup_device.py"
  File "..\..\requirements.txt"
  File "..\..\README.md"

  ; Windows helper scripts + bundled NSSM.
  File "install-service.ps1"
  File "caddy-wizard.ps1"
  File "breeze-tripwire.ps1"
  File "Caddyfile.example"
  File "pair.cmd"
  File "vendor\nssm.exe"

  WriteRegStr HKLM "Software\BreezeCore" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\BreezeCore" "Version" "${VERSION}"

  ; Build venv + register the hardened service (LAN-first bind, LocalService).
  DetailPrint "Setting up Python venv and the BreezeCore service (needs internet)…"
  nsExec::ExecToLog '"$PS" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install-service.ps1" -Action Install -InstallDir "$INSTDIR" -Nssm "$INSTDIR\nssm.exe"'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONEXCLAMATION "Service setup returned code $0.$\n$\nMost often this means Python 3.11+ wasn't found or dependencies couldn't be downloaded. Install Python 3.11+ (python.org / winget) and re-run, or run install-service.ps1 manually. Details are in the install log above."
  ${EndIf}

  ; Start-menu shortcuts.
  CreateDirectory "$SMPROGRAMS\Breeze Core"
  CreateShortcut "$SMPROGRAMS\Breeze Core\Pair AC units.lnk" "$INSTDIR\pair.cmd"
  CreateShortcut "$SMPROGRAMS\Breeze Core\Set up Caddy reverse proxy.lnk" "$PS" '-NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\caddy-wizard.ps1"'
  CreateShortcut "$SMPROGRAMS\Breeze Core\Edit service (nssm).lnk" "$INSTDIR\nssm.exe" 'edit BreezeCore'
  CreateShortcut "$SMPROGRAMS\Breeze Core\Uninstall.lnk" "$INSTDIR\uninstall.exe"

  ; Uninstall registration.
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BreezeCore" "DisplayName" "Breeze Core"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BreezeCore" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BreezeCore" "Publisher" "Breeze Core"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BreezeCore" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BreezeCore" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BreezeCore" "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BreezeCore" "NoRepair" 1
SectionEnd

Section /o "Caddy reverse proxy (guided setup)" SEC_CADDY
  ; Nothing to copy (the wizard ships with the server component); this just
  ; opts you into running the guided Caddy wizard on the final page.
  StrCpy $RunWizard 1
SectionEnd

; Component descriptions.
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_SERVER} "The Breeze Core server, run as a hardened Windows service (bundled NSSM, low-privilege account, LAN-locked firewall). Required."
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_CADDY} "Optional: run the guided Caddy reverse-proxy wizard at the end for public HTTPS (auto-TLS, hardened headers, LAN-only admin, fail2ban-style banning). You can also run it later from the Start menu."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ---------------------------------------------------------------- Functions
Function .onInit
  StrCpy $RunWizard 0
  StrCpy $PS "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
FunctionEnd

; Pre-check the "set up Caddy" finish checkbox iff the component was selected.
Function finishShow
  ${If} $RunWizard == 1
    SendMessage $mui.FinishPage.ShowReadme ${BM_SETCHECK} ${BST_CHECKED} 0
  ${EndIf}
FunctionEnd

; Launch the Caddy wizard in its own elevated PowerShell window.
Function RunCaddyWizard
  Exec '"$PS" -NoProfile -ExecutionPolicy Bypass -NoExit -File "$INSTDIR\caddy-wizard.ps1"'
FunctionEnd

; ---------------------------------------------------------------- Uninstaller
Section "Uninstall"
  StrCpy $PS "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"

  ; Remove the BreezeCore service + its firewall rules (keeps the data dir).
  nsExec::ExecToLog '"$PS" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install-service.ps1" -Action Uninstall -InstallDir "$INSTDIR" -Nssm "$INSTDIR\nssm.exe"'
  Pop $0

  ; Remove Caddy + tripwire services and their firewall rules, if present.
  nsExec::ExecToLog '"$INSTDIR\nssm.exe" stop BreezeCaddy confirm'
  nsExec::ExecToLog '"$INSTDIR\nssm.exe" remove BreezeCaddy confirm'
  nsExec::ExecToLog '"$INSTDIR\nssm.exe" stop BreezeTripwire confirm'
  nsExec::ExecToLog '"$INSTDIR\nssm.exe" remove BreezeTripwire confirm'
  nsExec::ExecToLog '"$PS" -NoProfile -ExecutionPolicy Bypass -Command "Get-NetFirewallRule -DisplayName ''Breeze *'' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; Get-NetFirewallRule -DisplayName ''BreezeBan *'' -ErrorAction SilentlyContinue | Remove-NetFirewallRule"'

  Delete "$SMPROGRAMS\Breeze Core\*.lnk"
  RMDir "$SMPROGRAMS\Breeze Core"

  ; App files (leave the data dir under %ProgramData%\breeze-core in place).
  RMDir /r "$INSTDIR\meow_ac"
  RMDir /r "$INSTDIR\static"
  RMDir /r "$INSTDIR\venv"
  RMDir /r "$INSTDIR\caddy"
  Delete "$INSTDIR\*.ps1"
  Delete "$INSTDIR\*.cmd"
  Delete "$INSTDIR\*.py"
  Delete "$INSTDIR\*.txt"
  Delete "$INSTDIR\*.md"
  Delete "$INSTDIR\Caddyfile.example"
  Delete "$INSTDIR\nssm.exe"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BreezeCore"
  DeleteRegKey HKLM "Software\BreezeCore"

  MessageBox MB_OK "Breeze Core removed.$\n$\nYour configuration and device tokens were kept in:$\n    %ProgramData%\breeze-core$\nDelete that folder by hand if you want them gone."
SectionEnd
