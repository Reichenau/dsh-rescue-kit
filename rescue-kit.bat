@echo off
rem Build a rescue kit zip. Double-click this file.
rem Pure ASCII on purpose: cmd.exe would garble UTF-8 Chinese in a .bat.
setlocal

rem The symptom travels in an ENVIRONMENT VARIABLE, not through a temp file:
rem "echo %SYMPTOM% > file" breaks the moment the text contains & | < > ^ %
rem and the answers to "why did it break" are exactly that kind of text.
set "DSH_RESCUE_SYMPTOM="

echo.
echo  DSH rescue kit - collects evidence about a broken agent into .\reports
echo.
echo  What did you actually see on screen? (one line, or press Enter to skip)
echo    e.g. window went white / chat stopped replying / app closes on start
echo.
set /p "DSH_RESCUE_SYMPTOM=> "

echo.
echo Running... this takes about 30 seconds and prints one line per step.
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
