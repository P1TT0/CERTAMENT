@echo off
:: ============================================================
::  CERTAMENT - Launcher Installer
::  Tasto destro -> "Esegui come amministratore"
:: ============================================================

:: Verifica privilegi di amministratore
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   Richiesti privilegi di Amministratore.
    echo   Rilancio con elevazione...
    echo.
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

:: Avvia l'installer PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Certament.ps1" -WaitAtEnd

exit /b
