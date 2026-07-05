@echo off
rem Pair / discover Midea units and write config.json. Prints the API key ONCE.
setlocal
if "%AC_CONFIG%"=="" set "AC_CONFIG=%ProgramData%\breeze-core\config.json"
echo Pairing Breeze Core units into "%AC_CONFIG%".
echo Save the API key it prints -- you need it to connect the app/UI.
echo.
"%~dp0venv\Scripts\python.exe" "%~dp0setup_device.py" %*
echo.
echo When it has found your units, start the service:
echo     nssm start BreezeCore      ^(or: sc start BreezeCore^)
echo.
pause
