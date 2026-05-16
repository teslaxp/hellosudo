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
$Script:GPIniPath   = "$env:SystemRoot\System32\GroupPolicy\Machine\Scripts\scripts.ini"
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

    # Log writes are observational infrastructure — always execute even under -WhatIf.
    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force -WhatIf:$false | Out-Null
    }
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 -WhatIf:$false

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

    # Prefer Windows 11 built-in sudo when available AND enabled in Settings.
    # sudo.exe is present on Windows 11 24H2+ even when the feature is disabled,
    # so we must verify the registry toggle before attempting to use it.
    $sudoEnabled = $false
    $sudoExe     = Get-Command sudo -CommandType Application -ErrorAction SilentlyContinue
    if ($sudoExe) {
        try {
            $sudoReg     = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' `
                               -Name 'Enabled' -ErrorAction SilentlyContinue
            # Enabled: 0=disabled, 1=new-window, 2=input-disabled, 3=inline
            $sudoEnabled = ($null -ne $sudoReg) -and ([int]$sudoReg.Enabled -ge 1)
        } catch {}
    }

    if ($sudoEnabled) {
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
$originalDisabledState   = if ($null -ne $meta.OriginalDisabledState)   { [int]$meta.OriginalDisabledState }   else { 0 }
# OriginalDisabledExisted: 1=value was present, 0=value was absent (written by install.ps1 >= v2).
# Fall back to ($originalDisabledState -ne 0) for backward compatibility with older metadata.
$originalDisabledExisted = if ($meta.PSObject.Properties['OriginalDisabledExisted']) {
    [bool]([int]$meta.OriginalDisabledExisted)
} else {
    $originalDisabledState -ne 0
}
$installedTasks          = if ($meta.InstalledTasks)     { $meta.InstalledTasks   -split ',' | Where-Object { $_ } } else { @() }
$installedGP             = if ($meta.InstalledGPScripts) { $meta.InstalledGPScripts -split ',' | Where-Object { $_ } } else { @() }
$originalConsentBehavior = if ($meta.PSObject.Properties['OriginalConsentBehavior']) { [int]$meta.OriginalConsentBehavior } else { 5 }
$originalSecureDesktop   = if ($meta.PSObject.Properties['OriginalSecureDesktop'])   { [int]$meta.OriginalSecureDesktop }   else { 1 }

Write-Log "TargetGUID              : $targetGUID"
Write-Log "OriginalDisabledExisted : $originalDisabledExisted"
Write-Log "OriginalDisabledState   : $originalDisabledState"
Write-Log "InstalledTasks          : $($installedTasks -join ', ')"
Write-Log "InstalledGPScripts      : $($installedGP -join ', ')"
Write-Log "OriginalConsentBehavior : $originalConsentBehavior"
Write-Log "OriginalSecureDesktop   : $originalSecureDesktop"
#endregion

#region ── Remove Scheduled Tasks ────────────────────────────────────────────────
Write-LogHost 'Removing scheduled tasks...' -Color Cyan

foreach ($taskName in @($Script:TaskDisable, $Script:TaskRestore)) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($taskName, 'Unregister scheduled task')) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-LogHost "  Removed task: $taskName" -Color Green
        }
    } else {
        Write-Log "  Task not found (already removed?): $taskName" -Level WARN
    }
}
#endregion

#region ── Clean GPO Script INI Files ────────────────────────────────────────────
function Remove-UacbioGpoBlock {
    <#
    .SYNOPSIS
        Removes the uacbio-added lines from the specified section of scripts.ini.
        Scopes the search to the target section so that removing one section's
        block does not affect another section's block in the same file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$IniPath,
        [Parameter(Mandatory)][string]$Section    # e.g. 'Shutdown' or 'Startup'
    )

    if (-not (Test-Path $IniPath)) {
        Write-Log "GPO ini not found, nothing to clean: $IniPath" -Level WARN
        return
    }

    $lines         = Get-Content $IniPath -Encoding Unicode
    $sectionHeader = "[$Section]"
    $marker        = '# uacbio'

    # Locate the target section header
    $sectionStart = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq $sectionHeader) { $sectionStart = $i; break }
    }

    if ($null -eq $sectionStart) {
        Write-Log "Section '$sectionHeader' not found in '$IniPath' — nothing to remove."
        return
    }

    # Determine where this section ends (next section header or EOF)
    $sectionEnd = $lines.Count - 1
    for ($i = $sectionStart + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[') { $sectionEnd = $i - 1; break }
    }

    # Collect marker indices only within this section
    $markerIndices = @()
    for ($i = $sectionStart; $i -le $sectionEnd; $i++) {
        if ($lines[$i] -eq $marker) { $markerIndices += $i }
    }

    if ($markerIndices.Count -eq 0) {
        Write-Log "No uacbio marker found in [$Section] section of '$IniPath' — nothing to remove."
        return
    }

    # Remove from bottom up to keep earlier indices stable
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

    if ($PSCmdlet.ShouldProcess($IniPath, "Remove uacbio [$Section] script block")) {
        Set-Content -Path $IniPath -Value $result.ToArray() -Encoding Unicode
        Write-Log "Cleaned uacbio block from [$Section] section of '$IniPath'."
    }
}

$gpupdateNeeded = $false

if ($installedGP -contains 'Shutdown') {
    Write-LogHost "Cleaning GPO [Shutdown] section from scripts.ini ..." -Color Cyan
    Remove-UacbioGpoBlock -IniPath $Script:GPIniPath -Section 'Shutdown'
    $gpupdateNeeded = $true
}

if ($installedGP -contains 'Startup') {
    Write-LogHost "Cleaning GPO [Startup] section from scripts.ini ..." -Color Cyan
    Remove-UacbioGpoBlock -IniPath $Script:GPIniPath -Section 'Startup'
    $gpupdateNeeded = $true
}

if ($gpupdateNeeded) {
    Write-LogHost 'Running gpupdate /force ...' -Color Cyan
    if ($PSCmdlet.ShouldProcess('Group Policy', 'Run gpupdate /force')) {
        try {
            $gp = & gpupdate /force 2>&1
            Write-Log "gpupdate output: $($gp -join ' ')"
            Write-LogHost 'Group Policy updated.' -Color Green
        } catch {
            Write-Log "gpupdate failed: $_" -Level WARN
        }
    }
}
#endregion

#region ── Revert UAC Secure Desktop Policy ──────────────────────────────────────
$uacPolicyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Write-LogHost 'Reverting UAC Secure Desktop policy to original values...' -Color Cyan

if ($PSCmdlet.ShouldProcess($uacPolicyKey, "Restore ConsentPromptBehaviorAdmin = $originalConsentBehavior")) {
    try {
        Set-ItemProperty -Path $uacPolicyKey -Name 'ConsentPromptBehaviorAdmin' -Value $originalConsentBehavior -Type DWord
        Write-Log "Restored ConsentPromptBehaviorAdmin = $originalConsentBehavior."
    } catch {
        Write-Log "Failed to restore ConsentPromptBehaviorAdmin: $_" -Level WARN
        Write-LogHost "  WARNING: Could not restore ConsentPromptBehaviorAdmin. Set manually to $originalConsentBehavior." -Level WARN -Color Yellow
    }
}

if ($PSCmdlet.ShouldProcess($uacPolicyKey, "Restore PromptOnSecureDesktop = $originalSecureDesktop")) {
    try {
        Set-ItemProperty -Path $uacPolicyKey -Name 'PromptOnSecureDesktop' -Value $originalSecureDesktop -Type DWord
        Write-Log "Restored PromptOnSecureDesktop = $originalSecureDesktop."
    } catch {
        Write-Log "Failed to restore PromptOnSecureDesktop: $_" -Level WARN
        Write-LogHost "  WARNING: Could not restore PromptOnSecureDesktop. Set manually to $originalSecureDesktop." -Level WARN -Color Yellow
    }
}

Write-LogHost "  UAC policy reverted successfully." -Color Green
#endregion

#region ── Revert Registry 'Disabled' Value ─────────────────────────────────────
Write-LogHost "Reverting credential provider 'Disabled' value..." -Color Cyan

$cpKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$targetGUID"

if (Test-Path $cpKeyPath) {
    if ($originalDisabledExisted) {
        # Value was explicitly present before install — restore it to its original DWORD
        if ($PSCmdlet.ShouldProcess($cpKeyPath, "Restore Disabled = $originalDisabledState")) {
            Set-ItemProperty -Path $cpKeyPath -Name 'Disabled' -Value $originalDisabledState -Type DWord
            Write-Log "Restored 'Disabled' to $originalDisabledState."
            Write-LogHost "  Registry reverted: Disabled = $originalDisabledState" -Color Green
        }
    } else {
        # Value was absent before install — remove it entirely rather than writing 0
        if ($PSCmdlet.ShouldProcess($cpKeyPath, 'Remove Disabled value (was absent before install)')) {
            try {
                Remove-ItemProperty -Path $cpKeyPath -Name 'Disabled' -ErrorAction SilentlyContinue
                Write-Log "Removed 'Disabled' value (restoring to original absent state)."
                Write-LogHost "  Registry reverted: Disabled value removed (was originally absent)." -Color Green
            } catch {
                Write-Log "Could not remove 'Disabled' value: $_" -Level WARN
                Write-LogHost "  WARNING: Could not remove 'Disabled' value. Remove manually from: $cpKeyPath" -Level WARN -Color Yellow
            }
        }
    }
} else {
    Write-LogHost "Credential provider key not found at '$cpKeyPath' — skipping revert." -Level WARN -Color Yellow
}
#endregion

#region ── Remove Metadata Registry Key ──────────────────────────────────────────
Write-LogHost "Removing HKLM:\SOFTWARE\uacbio metadata key ..." -Color Cyan

if ($PSCmdlet.ShouldProcess($Script:MetaKey, 'Remove metadata registry key')) {
    try {
        Remove-Item -Path $Script:MetaKey -Recurse -Force
        Write-Log "Metadata key removed."
        Write-LogHost "  Metadata key removed." -Color Green
    } catch {
        Write-Log "Failed to remove metadata key: $_" -Level WARN
        Write-LogHost "  WARNING: Could not remove metadata key. Remove manually: $($Script:MetaKey)" -Level WARN -Color Yellow
    }
}
#endregion

#region ── Remove Data Directory (if empty) ──────────────────────────────────────
Write-LogHost "Checking if C:\ProgramData\uacbio can be removed ..." -Color Cyan

Write-Log "Uninstallation complete. Checking data directory for cleanup."

$remaining = Get-ChildItem -Path $Script:DataDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $Script:LogFile }

if ($null -eq $remaining -or $remaining.Count -eq 0) {
    if ($PSCmdlet.ShouldProcess($Script:DataDir, 'Remove data directory')) {
        try {
            Remove-Item -Path $Script:DataDir -Recurse -Force
            Write-Host "  Data directory removed: $($Script:DataDir)" -ForegroundColor Green
        } catch {
            Write-Host "  WARNING: Could not fully remove data directory. Remove manually: $($Script:DataDir)" -ForegroundColor Yellow
        }
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
