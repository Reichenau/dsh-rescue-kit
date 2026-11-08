@echo off
rem Build a rescue kit zip. Double-click this file.
rem Pure ASCII on purpose: cmd.exe would garble UTF-8 Chinese in a .bat.
setlocal

rem The symptom is asked by PowerShell (Read-Host), not here: cmd.exe's
rem "set /p" plus "chcp 65001" mangles non-ASCII text before PowerShell sees it.

echo.
echo  DSH rescue kit - collects evidence about a broken agent into .\reports
echo.
echo  Answer the "what did you see" question the kit asks next.
echo  Running... this takes 30-60 seconds and prints one line per step.
echo  If this window is closed mid-run, a "_tmp" folder may be left next to this file:
echo  zip that folder by hand and send it too - it still holds partial evidence.
echo.

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-rescue-kit.ps1" %*
if errorlevel 1 goto failed

echo.
set "LAST="
rem PARTIAL-*.zip is a salvage package, not a finished report: skip it when
rem picking the newest file, or the user is told "OK" and opens a broken zip.
for /f "delims=" %%f in ('dir /b /o-d "%~dp0reports\*.zip" 2^>nul ^| findstr /v /b "PARTIAL-"') do if not defined LAST set "LAST=%%f"
if defined LAST echo OK. Newest report: %LAST%
echo Look in the "reports" folder next to this file.
if exist "%~dp0_tmp" echo [!] "_tmp" is still here - zip it by hand and send that too.
start "" "%~dp0reports"
echo.
pause
exit /b 0

:failed
echo.
echo [FAILED] The kit could not be built. Read the messages above.
echo If a "_tmp" folder is still present next to this file, zip it by hand and send that too.
echo.
pause
exit /b 1
