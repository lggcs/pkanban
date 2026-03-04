@echo off
:: Kanban Board Server Launcher
:: Launches the PowerShell server from the same directory as this batch file

:: Get the directory where this batch file is located
set "KANBANPATH=%~dp0"

:: Check if already running as admin
net session >nul 2>&1
if %errorlevel% == 0 (
    :: Running as admin - launch directly with network binding
    start "Kanban Board Server" powershell.exe -ExecutionPolicy Bypass -File "%KANBANPATH%server.ps1"
) else (
    :: Not admin - prompt to run as admin for network access
    echo.
    echo  Starting Kanban Board Server...
    echo.
    echo  NOTE: Running as Administrator allows network access.
    echo        Other users on the network can access the board.
    echo.
    choice /C YN /M "  Run as Administrator for network access"
    if errorlevel 2 (
        :: User chose N - run as regular user (localhost only)
        start "Kanban Board Server" powershell.exe -ExecutionPolicy Bypass -File "%KANBANPATH%server.ps1"
    ) else (
        :: User chose Y - elevate to admin
        powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -File \"%KANBANPATH%server.ps1\"' -Verb RunAs"
    )
)