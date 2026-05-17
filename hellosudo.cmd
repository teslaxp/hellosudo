@echo off
setlocal enabledelayedexpansion

::  hellosudo — biometric-first UAC helper
::  https://github.com/yourusername/hellosudo
::
::  Usage:
::    hellosudo on              Enable biometric-first mode (Disabled=1)
::    hellosudo off             Restore standard UAC mode (Disabled=0)
::    hellosudo status          Show current system state
::    hellosudo sudo <command>  Run command via Windows sudo
::
::  Requires Windows 11. Administrative elevation is requested as needed.

set "PROVIDER_GUID={60b78e88-ead8-445c-9cfd-0b87f74ea6cd}"
set "PROVIDER_KEY=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\%PROVIDER_GUID%"
set "UAC_KEY=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
set "SUDO_KEY=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo"

if "%~1"==""        goto :usage
if /i "%~1"=="on"   goto :cmd_on
if /i "%~1"=="off"  goto :cmd_off
if /i "%~1"=="status" goto :cmd_status
if /i "%~1"=="sudo" goto :cmd_sudo
if /i "%~1"=="help" goto :usage
if /i "%~1"=="/?"   goto :usage

echo [ERROR] Unknown command: %~1
goto :usage

:: ─────────────────────────────────────────────────────────────────
:cmd_on
:: Enable biometric-first mode: PasswordProvider Disabled=1
call :require_admin on %*
echo.
echo   Enabling biometric-first UAC mode...
reg add "%PROVIDER_KEY%" /v Disabled /t REG_DWORD /d 1 /f >nul 2>&1
if errorlevel 1 (
    echo   [FAIL] Could not write registry. Run as Administrator.
    exit /b 1
)
echo   [OK] PasswordProvider suppressed  ^(Disabled=1^)
echo   [OK] Windows Hello / PIN will now appear first in UAC prompts.
echo.
exit /b 0

:: ─────────────────────────────────────────────────────────────────
:cmd_off
:: Restore standard UAC mode: PasswordProvider Disabled=0
call :require_admin off %*
echo.
echo   Restoring standard UAC mode...
reg add "%PROVIDER_KEY%" /v Disabled /t REG_DWORD /d 0 /f >nul 2>&1
if errorlevel 1 (
    echo   [FAIL] Could not write registry. Run as Administrator.
    exit /b 1
)
echo   [OK] PasswordProvider restored  ^(Disabled=0^)
echo   [OK] Standard password+biometric UAC flow active.
echo.
exit /b 0

:: ─────────────────────────────────────────────────────────────────
:cmd_status
echo.
echo   hellosudo — system status
echo   ─────────────────────────────────────────────────────

:: PasswordProvider state
for /f "tokens=3" %%A in ('reg query "%PROVIDER_KEY%" /v Disabled 2^>nul') do set "DISABLED=%%A"
if not defined DISABLED (
    echo   PasswordProvider    : Disabled value absent  ^(enabled by default^)
) else if "%DISABLED%"=="0x0" (
    echo   PasswordProvider    : Enabled  ^(Disabled=0^)  — standard mode
) else if "%DISABLED%"=="0x1" (
    echo   PasswordProvider    : Suppressed  ^(Disabled=1^)  — biometric-first mode ACTIVE
) else (
    echo   PasswordProvider    : Disabled=%DISABLED%
)

:: UAC policy
for /f "tokens=3" %%A in ('reg query "%UAC_KEY%" /v ConsentPromptBehaviorAdmin 2^>nul') do set "CONSENT=%%A"
for /f "tokens=3" %%A in ('reg query "%UAC_KEY%" /v PromptOnSecureDesktop 2^>nul') do set "SECURE=%%A"
if not defined CONSENT set "CONSENT=unknown"
if not defined SECURE  set "SECURE=unknown"
echo   ConsentBehaviorAdmin: %CONSENT%   ^(1=credential prompt / biometric enabled^)
echo   PromptOnSecureDesktop: %SECURE%   ^(1=Secure Desktop enforced^)

:: sudo state
for /f "tokens=3" %%A in ('reg query "%SUDO_KEY%" /v Enabled 2^>nul') do set "SUDO_VAL=%%A"
if not defined SUDO_VAL (
    echo   Windows sudo        : Not configured
) else if "%SUDO_VAL%"=="0x0" (
    echo   Windows sudo        : Disabled
) else if "%SUDO_VAL%"=="0x3" (
    echo   Windows sudo        : Enabled  ^(normal / inline mode^)
) else if "%SUDO_VAL%"=="0x1" (
    echo   Windows sudo        : Enabled  ^(new window mode^)
) else if "%SUDO_VAL%"=="0x2" (
    echo   Windows sudo        : Enabled  ^(input disabled mode^)
) else (
    echo   Windows sudo        : Enabled  ^(mode=%SUDO_VAL%^)
)

:: hellosudo install state
reg query "HKLM\SOFTWARE\hellosudo" >nul 2>&1
if not errorlevel 1 (
    echo   hellosudo install   : Active  ^(metadata found^)
) else (
    reg query "HKLM\SOFTWARE\uacbio" >nul 2>&1
    if not errorlevel 1 (
        echo   hellosudo install   : Legacy uacbio install found
    ) else (
        echo   hellosudo install   : Not installed
    )
)

echo   ─────────────────────────────────────────────────────
echo.
exit /b 0

:: ─────────────────────────────────────────────────────────────────
:cmd_sudo
:: Wrapper around Windows sudo
shift
if "%~1"=="" (
    echo   Usage: hellosudo sudo ^<command^> [args...]
    exit /b 1
)
where sudo >nul 2>&1
if errorlevel 1 (
    echo   [ERROR] sudo.exe not found. Requires Windows 11 24H2 or later.
    echo   Enable via: Settings ^> System ^> For developers ^> Enable sudo
    exit /b 1
)
sudo %*
exit /b %errorlevel%

:: ─────────────────────────────────────────────────────────────────
:require_admin
:: Self-elevate if not already running as Administrator.
:: %1=original subcommand, %2 onwards=full args (not used here, elevation re-runs the same cmd)
net session >nul 2>&1
if not errorlevel 1 exit /b 0
echo   Requesting Administrator elevation...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs -Wait"
exit /b %errorlevel%

:: ─────────────────────────────────────────────────────────────────
:usage
echo.
echo   hellosudo — biometric-first UAC for Windows 11
echo.
echo   Usage:
echo     hellosudo on              Enable biometric-first UAC  ^(Disabled=1^)
echo     hellosudo off             Restore standard UAC  ^(Disabled=0^)
echo     hellosudo status          Show current system state
echo     hellosudo sudo ^<command^>  Run command with Windows sudo
echo.
echo   Examples:
echo     hellosudo status
echo     hellosudo on
echo     hellosudo sudo powershell
echo     hellosudo sudo "reg query HKLM\SOFTWARE\hellosudo"
echo.
exit /b 0
