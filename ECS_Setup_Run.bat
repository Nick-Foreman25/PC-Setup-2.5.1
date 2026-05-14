@echo off
:: ECS Setup Automation Batch Script
:: Runs ECS PC config, File Explorer tweaks, and GPO import if desired

:: === Step 0: Check for Admin Privileges ===
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo [!] Please run this script as Administrator!
    pause
    exit /b
)

:: === Step 1: Run PowerShell Setup Script ===
echo [*] Running ECS PowerShell Setup...
PowerShell -ExecutionPolicy Bypass -File "%~dp0ECS_Setup_Automation\ecs_config_interactive.ps1"
pause

:: === Step 2: Apply File Explorer Tweaks ===
echo [*] Applying File Explorer tweaks...
reg import explorer_tweaks.reg

:: === Step 3: GPO Settings (if present) ===
if exist "LGPO_Tool\LGPO.exe" (
    echo [*] LGPO.exe found.
    if exist "GPO_Backup\Machine\registry.pol" (
        echo [*] GPO Backup found.
        set /p runGPO="Do you want to apply GPO settings now? (y/n): "
        if /i "%runGPO%"=="y" (
            LGPO_Tool\LGPO.exe /g GPO_Backup
        )
    ) else (
        echo [!] GPO Backup missing (GPO_Backup\Machine\registry.pol)
    )
) else (
    echo [!] LGPO tool missing (LGPO_Tool\LGPO.exe)
)

:: === Step 4: Prompt for Restart ===
echo.
set /p doRestart="Setup complete. Restart now? (y/n): "
if /i "%doRestart%"=="y" (
    shutdown /r /t 5
)
exit