@echo off
setlocal
title CERTAMENT - Scenario Tests

:: Require elevation because the runner changes BC, IIS, HTTP.sys and certificates.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   Administrative privileges are required. Relaunching elevated...
    powershell.exe -NoProfile -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

pushd "%~dp0"
echo.
echo   CERTAMENT scenario suite: ALL
 echo   Each scenario restores the baseline automatically.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TESTER\certament-runner-v8.1\CertamentScenarioRunner.ps1" -Action RunSuite -Suite All
set "exitCode=%errorlevel%"
popd

echo.
if not "%exitCode%"=="0" echo   Suite finished with errors. Check the report under C:\ProgramData\EOS\Certament\ScenarioRunnerV8.
pause
exit /b %exitCode%
