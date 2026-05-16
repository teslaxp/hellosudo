#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls uacbio — removes all scheduled tasks, GPO scripts, and reverts
    the PasswordProvider credential provider registry state.

.DESCRIPTION
    Reads installation metadata from HKLM:\SOFTWARE\uacbio to discover what
    was installed, then cleanly reverses every change made by install.ps1.

.EXAMPLE
    .\uninstall.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Constants ────────────────────────────────────────────────────────────
$Script:LogDir      = 'C:\ProgramData\uacbio\logs'
$Script:LogFile     = Join-Path $Script:LogDir 'uninstall.log'
$Script:MetaKey     = 'HKLM:\SOFTWARE\uacbio'
$Script:TaskDisable = 'uacbio_Disable_Password'
$Script:TaskRestore = 'uacbio_Restore_Password'
$Script:GPMachine   = "$env:SystemRoot\System32\GroupPolicy\Machine\Scripts"
$Script:DataDir     = 'C:\ProgramData\uacbio'
#endregion

#region ── Logging ──────────────────────────────────────────────────────────────
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$stamp] [$Level] $Message"

    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    }
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8

    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error   $Message -ErrorAction Continue }
        default { Write-Verbose $Message }
    }
}

function Write-LogHost {
    param([string]$Message, [string]$Level = 'INFO', [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Log -Message $Message -Level $Level
    Write-Host $Message -ForegroundColor $Color
}
#endregion

#region ── Admin Elevation ───────────────────────────────────────────────────────
function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevate {
    $scriptPath = $MyInvocation.PSCommandPath
    $pwsh       = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }

    $sudoAvail = $false
    try {
        $sudoAvail = [bool](Get-Command sudo -CommandType Application -ErrorAction SilentlyContinue)
    } catch {}

    if ($sudoAvail) {
        Write-Host 'Elevating via sudo...' -ForegroundColor Cyan
        & sudo $pwsh -NoProfile -ExecutionPolicy Bypass -File "`"$scriptPath`""
    } else {
        Write-Host 'Elevating via Start-Process RunAs...' -ForegroundColor Cyan
        Start-Process -FilePath $pwsh `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
            -Verb RunAs
    }
    exit 0
}

if (-not (Test-IsAdmin)) { Invoke-SelfElevate }
#endregion

#region ── Log Banner ────────────────────────────────────────────────────────────
Write-LogHost ('=' * 60) -Color Cyan
Write-LogHost ' uacbio  —  Uninstallation Script' -Color Cyan
Write-LogHost ('=' * 60) -Color Cyan
#endregion

#region ── Read Metadata ─────────────────────────────────────────────────────────
Write-LogHost 'Reading installation metadata from HKLM:\SOFTWARE\uacbio ...' -Color Cyan

if (-not (Test-Path $Script:MetaKey)) {
    $msg = "Metadata key '$($Script:MetaKey)' not found. uacbio may not be installed, or was already uninstalled."
    Write-LogHost $msg -Level ERROR -Color Red
    Write-Host 'Uninstallation aborted.' -ForegroundColor Red
    exit 1
}

$meta = Get-ItemProperty -Path $Script:MetaKey

$targetGUID              = $meta.TargetGUID
$originalDisabled        = [int]$meta.OriginalDisabledState
$installedTasks          = if ($meta.InstalledTasks)     { $meta.InstalledTasks   -split ',' | Where-Object { $_ } } else { @() }
$installedGP             = if ($meta.InstalledGPScripts) { $meta.InstalledGPScripts -split ',' | Where-Object { $_ } } else { @() }
$originalConsentBehavior = if ($null -ne $meta.OriginalConsentBehavior) { [int]$meta.OriginalConsentBehavior } else { 5 }
$originalSecureDesktop   = if ($null -ne $meta.OriginalSecureDesktop)   { [int]$meta.OriginalSecureDesktop }   else { 1 }

Write-Log "TargetGUID              : $targetGUID"
Write-Log "OriginalDisabledState   : $originalDisabled"
Write-Log "InstalledTasks          : $($installedTasks -join ', ')"
Write-Log "InstalledGPScripts      : $($installedGP -join ', ')"
Write-Log "OriginalConsentBehavior : $originalConsentBehavior"
Write-Log "OriginalSecureDesktop   : $originalSecureDesktop"
#endregion

#region ── Remove Scheduled Tasks ────────────────────────────────────────────────
Write-LogHost 'Removing scheduled tasks...' -Color Cyan

foreach ($taskName in @($Script:TaskDisable, $Script:TaskRestore)) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-LogHost "  Removed task: $taskName" -Color Green
    } else {
        Write-Log "  Task not found (already removed?): $taskName" -Level WARN
    }
}
#endregion

#region ── Clean GPO Script INI Files ────────────────────────────────────────────
function Remove-UacbioGpoBlock {
    <#
    .SYNOPSIS
        Removes the lines that were added by uacbio from a GPO scripts .ini file.
        Identifies the block using the '# uacbio' marker line and removes the
        two preceding lines (CmdLine and Parameters entries) plus the marker itself.
    #>
    param([Parameter(Mandatory)][string]$IniPath)

    if (-not (Test-Path $IniPath)) {
        Write-Log "GPO ini not found, nothing to clean: $IniPath" -Level WARN
        return
    }

    $lines  = Get-Content $IniPath -Encoding Unicode
    $marker = '# uacbio'
    $markerIndices = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match [regex]::Escape($marker)) {
            $markerIndices += $i
        }
    }

    if ($markerIndices.Count -eq 0) {
        Write-Log "No uacbio marker found in '$IniPath' — nothing to remove."
        return
    }

    # Remove from bottom up to keep indices stable
    $result = [System.Collections.Generic.List[string]]($lines)
    foreach ($idx in ($markerIndices | Sort-Object -Descending)) {
        # Remove marker line
        $result.RemoveAt($idx)
        # Remove the Parameters line directly above (if present and matches pattern)
        if ($idx - 1 -ge 0 -and $result[$idx - 1] -match '^\d+Parameters=') {
            $result.RemoveAt($idx - 1)
            $idx--
        }
        # Remove the CmdLine line directly above (if present and matches pattern)
        if ($idx - 1 -ge 0 -and $result[$idx - 1] -match '^\d+CmdLine=') {
            $result.RemoveAt($idx - 1)
        }
    }

    Set-Content -Path $IniPath -Value $result.ToArray() -Encoding Unicode
    Write-Log "Cleaned uacbio block from '$IniPath'."
}

$gpupdateNeeded = $false

if ($installedGP -contains 'Shutdown') {
    $iniPath = Join-Path $Script:GPMachine 'Scripts\shutdown.ini'
    Write-LogHost "Cleaning GPO shutdown.ini ..." -Color Cyan
    Remove-UacbioGpoBlock -IniPath $iniPath
    $gpupdateNeeded = $true
}

if ($installedGP -contains 'Startup') {
    $iniPath = Join-Path $Script:GPMachine 'Scripts\startup.ini'
    Write-LogHost "Cleaning GPO startup.ini ..." -Color Cyan
    Remove-UacbioGpoBlock -IniPath $iniPath
    $gpupdateNeeded = $true
}

if ($gpupdateNeeded) {
    Write-LogHost 'Running gpupdate /force ...' -Color Cyan
    try {
        $gp = & gpupdate /force 2>&1
        Write-Log "gpupdate output: $($gp -join ' ')"
        Write-LogHost 'Group Policy updated.' -Color Green
    } catch {
        Write-Log "gpupdate failed: $_" -Level WARN
    }
}
#endregion

#region ── Revert UAC Secure Desktop Policy ──────────────────────────────────────
$uacPolicyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Write-LogHost 'Reverting UAC Secure Desktop policy to original values...' -Color Cyan

try {
    Set-ItemProperty -Path $uacPolicyKey -Name 'ConsentPromptBehaviorAdmin' -Value $originalConsentBehavior -Type DWord
    Write-Log "Restored ConsentPromptBehaviorAdmin = $originalConsentBehavior."

    Set-ItemProperty -Path $uacPolicyKey -Name 'PromptOnSecureDesktop' -Value $originalSecureDesktop -Type DWord
    Write-Log "Restored PromptOnSecureDesktop = $originalSecureDesktop."

    Write-LogHost "  UAC policy reverted successfully." -Color Green
} catch {
    Write-Log "Failed to revert UAC policy values: $_" -Level WARN
    Write-LogHost "  WARNING: Could not revert UAC policy. Restore manually — ConsentPromptBehaviorAdmin=$originalConsentBehavior, PromptOnSecureDesktop=$originalSecureDesktop" -Level WARN -Color Yellow
}
#endregion

#region ── Revert Registry 'Disabled' Value ─────────────────────────────────────
Write-LogHost "Reverting credential provider 'Disabled' value to $originalDisabled ..." -Color Cyan

$cpKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$targetGUID"

if (Test-Path $cpKeyPath) {
    if ($originalDisabled -eq 0) {
        # Remove the value entirely if it didn't exist originally (0 = not set / enabled)
        try {
            Remove-ItemProperty -Path $cpKeyPath -Name 'Disabled' -ErrorAction SilentlyContinue
            Write-Log "Removed 'Disabled' value (restoring to default enabled state)."
        } catch {
            Write-Log "Could not remove 'Disabled' value: $_" -Level WARN
        }
    } else {
        Set-ItemProperty -Path $cpKeyPath -Name 'Disabled' -Value $originalDisabled -Type DWord
        Write-Log "Set 'Disabled' to $originalDisabled."
    }
    Write-LogHost "  Registry reverted successfully." -Color Green
} else {
    Write-LogHost "Credential provider key not found at '$cpKeyPath' — skipping revert." -Level WARN -Color Yellow
}
#endregion

#region ── Remove Metadata Registry Key ──────────────────────────────────────────
Write-LogHost "Removing HKLM:\SOFTWARE\uacbio metadata key ..." -Color Cyan

try {
    Remove-Item -Path $Script:MetaKey -Recurse -Force
    Write-Log "Metadata key removed."
    Write-LogHost "  Metadata key removed." -Color Green
} catch {
    Write-Log "Failed to remove metadata key: $_" -Level WARN
    Write-LogHost "  WARNING: Could not remove metadata key. Remove manually: $($Script:MetaKey)" -Level WARN -Color Yellow
}
#endregion

#region ── Remove Data Directory (if empty) ──────────────────────────────────────
Write-LogHost "Checking if C:\ProgramData\uacbio can be removed ..." -Color Cyan

# The log directory contains our own log — flush it first, then check
Write-Log "Uninstallation complete. Checking data directory for cleanup."

$remaining = Get-ChildItem -Path $Script:DataDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $Script:LogFile }

if ($null -eq $remaining -or $remaining.Count -eq 0) {
    try {
        # Small files only remain (our own log); remove everything
        Remove-Item -Path $Script:DataDir -Recurse -Force
        Write-Host "  Data directory removed: $($Script:DataDir)" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Could not fully remove data directory. Remove manually: $($Script:DataDir)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Data directory not empty — left in place: $($Script:DataDir)" -ForegroundColor Yellow
    Write-Host "  Remaining files:" -ForegroundColor Yellow
    $remaining | ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor Yellow }
}
#endregion

#region ── Summary ───────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Green
Write-Host ' uacbio uninstallation complete.' -ForegroundColor Green
Write-Host ('=' * 60) -ForegroundColor Green
#endregion
