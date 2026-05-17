#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls hellosudo — removes all scheduled tasks, GPO scripts, and reverts
    the PasswordProvider credential provider registry state.

.DESCRIPTION
    Reads installation metadata from HKLM:\SOFTWARE\hellosudo to discover what
    was installed, then cleanly reverses every change made by install.ps1.
    Falls back to HKLM:\SOFTWARE\uacbio for legacy uacbio v1.x installs.

.EXAMPLE
    .\uninstall.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Constants ────────────────────────────────────────────────────────────
$Script:LogDir      = 'C:\ProgramData\hellosudo\logs'
$Script:LogFile     = Join-Path $Script:LogDir 'uninstall.log'
$Script:MetaKey     = 'HKLM:\SOFTWARE\hellosudo'
$Script:TaskPath    = '\hellosudo\'
$Script:TaskDisable = 'hellosudo_Disable_Password'
$Script:TaskRestore = 'hellosudo_Restore_Password'
$Script:GPIniPath   = "$env:SystemRoot\System32\GroupPolicy\Machine\Scripts\scripts.ini"
$Script:DataDir     = 'C:\ProgramData\hellosudo'

# Legacy names from v1.x (uacbio) — checked during cleanup for backward compatibility
$Script:LegacyMetaKey     = 'HKLM:\SOFTWARE\uacbio'
$Script:LegacyTaskPath    = '\uacbio\'
$Script:LegacyTaskDisable = 'uacbio_Disable_Password'
$Script:LegacyTaskRestore = 'uacbio_Restore_Password'
$Script:LegacyDataDir     = 'C:\ProgramData\uacbio'
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
Write-LogHost ' hellosudo  —  Uninstallation Script' -Color Cyan
Write-LogHost ('=' * 60) -Color Cyan
#endregion

#region ── Read Metadata ─────────────────────────────────────────────────────────
Write-LogHost 'Reading installation metadata...' -Color Cyan

$activeMetaKey = $null
if (Test-Path $Script:MetaKey) {
    $activeMetaKey = $Script:MetaKey
    Write-Log "Found metadata at: $Script:MetaKey"
} elseif (Test-Path $Script:LegacyMetaKey) {
    $activeMetaKey = $Script:LegacyMetaKey
    Write-Log "Found legacy metadata at: $Script:LegacyMetaKey (uacbio v1.x install detected)"
    Write-LogHost '  Legacy uacbio installation detected — performing full cleanup.' -Color Yellow
}

if ($null -eq $activeMetaKey) {
    $msg = "No installation metadata found (checked: $($Script:MetaKey), $($Script:LegacyMetaKey)). hellosudo may not be installed."
    Write-LogHost $msg -Level ERROR -Color Red
    Write-Host 'Uninstallation aborted.' -ForegroundColor Red
    exit 1
}

$meta = Get-ItemProperty -Path $activeMetaKey

$targetGUID              = $meta.TargetGUID
$originalDisabledState   = if ($null -ne $meta.OriginalDisabledState)   { [int]$meta.OriginalDisabledState }   else { 0 }
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

# Try current and legacy task names/paths
$taskPairs = @(
    @{ Path = $Script:TaskPath;       Disable = $Script:TaskDisable;       Restore = $Script:TaskRestore }
    @{ Path = $Script:LegacyTaskPath; Disable = $Script:LegacyTaskDisable; Restore = $Script:LegacyTaskRestore }
)

foreach ($pair in $taskPairs) {
    foreach ($taskName in @($pair.Disable, $pair.Restore)) {
        if (Get-ScheduledTask -TaskName $taskName -TaskPath $pair.Path -ErrorAction SilentlyContinue) {
            if ($PSCmdlet.ShouldProcess("$($pair.Path)$taskName", 'Unregister scheduled task')) {
                Unregister-ScheduledTask -TaskName $taskName -TaskPath $pair.Path -Confirm:$false
                Write-LogHost "  Removed task: $($pair.Path)$taskName" -Color Green
            }
        }
    }
}

# Remove Task Scheduler folders (current and legacy) if empty
foreach ($folderName in @('hellosudo', 'uacbio')) {
    $folderPath = "\$folderName\"
    if ($PSCmdlet.ShouldProcess($folderPath, 'Delete empty Task Scheduler folder')) {
        try {
            $schedService = New-Object -ComObject 'Schedule.Service'
            $schedService.Connect()
            $rootFolder   = $schedService.GetFolder('\')
            $tsFolder     = $null
            try { $tsFolder = $schedService.GetFolder($folderPath) } catch {}

            if ($null -ne $tsFolder) {
                $remainingTasks = $tsFolder.GetTasks(0)
                if ($remainingTasks.Count -eq 0) {
                    $rootFolder.DeleteFolder($folderName, 0)
                    Write-LogHost "  Task Scheduler folder '$folderPath' deleted." -Color Green
                } else {
                    Write-Log "Folder '$folderPath' still has $($remainingTasks.Count) task(s) — left in place." -Level WARN
                }
            }
        } catch {
            Write-Log "Could not manage Task Scheduler folder '$folderPath': $_" -Level WARN
        }
    }
}
#endregion

#region ── Clean GPO Script INI Files ────────────────────────────────────────────
function Remove-HellosudoGpoBlock {
    <#
    .SYNOPSIS
        Removes the hellosudo-added lines from the specified section of scripts.ini.
        Scopes the search to the target section so that removing one section's
        block does not affect another section's block in the same file.
    .NOTES
        Internal helper — no SupportsShouldProcess to avoid console-prompt hangs
        in non-interactive sudo sessions.
        Uses ArrayList throughout for reliable .Count under Set-StrictMode -Version Latest.
        Uses -LiteralPath to avoid wildcard expansion on bracket chars in paths.
    #>
    param(
        [Parameter(Mandatory)][string]$IniPath,
        [Parameter(Mandatory)][string]$Section,
        [string]$Marker = '# hellosudo'
    )
    $marker = $Marker

    if (-not (Test-Path -LiteralPath $IniPath)) {
        Write-Log "GPO ini not found, nothing to clean: $IniPath" -Level WARN
        return
    }

    # Load into ArrayList — .Count is a native .NET property, always reliable
    $lines = [System.Collections.ArrayList]::new()
    foreach ($line in (Get-Content -LiteralPath $IniPath -Encoding Unicode)) {
        [void]$lines.Add($line)
    }

    $sectionHeader = "[$Section]"

    # Locate the target section header
    $sectionStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq $sectionHeader) { $sectionStart = $i; break }
    }

    if ($sectionStart -eq -1) {
        Write-Log "Section '$sectionHeader' not found in '$IniPath' — nothing to remove."
        return
    }

    # Determine where this section ends (next section header or EOF)
    $sectionEnd = $lines.Count - 1
    for ($i = $sectionStart + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[') { $sectionEnd = $i - 1; break }
    }

    # Collect marker indices only within this section
    $markerIndices = [System.Collections.Generic.List[int]]::new()
    for ($i = $sectionStart; $i -le $sectionEnd; $i++) {
        if ($lines[$i] -eq $marker) { [void]$markerIndices.Add($i) }
    }

    if ($markerIndices.Count -eq 0) {
        Write-Log "No marker '$marker' found in [$Section] section of '$IniPath' — nothing to remove."
        return
    }

    # Remove from bottom up to keep earlier indices stable
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $lines) { [void]$result.Add($l) }

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

    Set-Content -LiteralPath $IniPath -Value $result.ToArray() -Encoding Unicode
    Write-Log "Cleaned '$marker' block from [$Section] section of '$IniPath'."
}

$gpupdateNeeded = $false

if ($installedGP -contains 'Shutdown') {
    Write-LogHost "Cleaning GPO [Shutdown] section from scripts.ini ..." -Color Cyan
    Remove-HellosudoGpoBlock -IniPath $Script:GPIniPath -Section 'Shutdown' -Marker '# hellosudo'
    Remove-HellosudoGpoBlock -IniPath $Script:GPIniPath -Section 'Shutdown' -Marker '# uacbio'
    $gpupdateNeeded = $true
}

if ($installedGP -contains 'Startup') {
    Write-LogHost "Cleaning GPO [Startup] section from scripts.ini ..." -Color Cyan
    Remove-HellosudoGpoBlock -IniPath $Script:GPIniPath -Section 'Startup' -Marker '# hellosudo'
    Remove-HellosudoGpoBlock -IniPath $Script:GPIniPath -Section 'Startup' -Marker '# uacbio'
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
# Always set Disabled=0 (provider enabled) on uninstall.
# Restoring the "original" value is unreliable: any logon between install and
# uninstall would have set Disabled=1 via the scheduled task, corrupting the
# saved original on any subsequent reinstall. When removing uacbio the user
# always wants the PasswordProvider active again (Disabled=0).
Write-LogHost "Re-enabling credential provider (Disabled=0)..." -Color Cyan

$cpKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$targetGUID"

if (Test-Path $cpKeyPath) {
    if ($PSCmdlet.ShouldProcess($cpKeyPath, 'Set Disabled = 0 (re-enable PasswordProvider)')) {
        Set-ItemProperty -Path $cpKeyPath -Name 'Disabled' -Value 0 -Type DWord
        Write-Log "Set 'Disabled' to 0 — PasswordProvider re-enabled."
        Write-LogHost "  PasswordProvider re-enabled: Disabled = 0" -Color Green
    }
} else {
    Write-LogHost "Credential provider key not found at '$cpKeyPath' — skipping." -Level WARN -Color Yellow
    Write-Log "Credential provider key not found at '$cpKeyPath' — skipping revert." -Level WARN
}
#endregion

#region ── Remove Metadata Registry Key ──────────────────────────────────────────
Write-LogHost 'Removing hellosudo metadata registry keys...' -Color Cyan

foreach ($keyToRemove in @($Script:MetaKey, $Script:LegacyMetaKey)) {
    if (Test-Path $keyToRemove) {
        if ($PSCmdlet.ShouldProcess($keyToRemove, 'Remove metadata registry key')) {
            try {
                Remove-Item -Path $keyToRemove -Recurse -Force
                Write-Log "Removed metadata key: $keyToRemove"
                Write-LogHost "  Metadata key removed: $keyToRemove" -Color Green
            } catch {
                Write-Log "Failed to remove key ${keyToRemove}: $_" -Level WARN
                Write-LogHost "  WARNING: Could not remove metadata key. Remove manually: $keyToRemove" -Level WARN -Color Yellow
            }
        }
    }
}
#endregion

#region ── Remove Data Directory (if empty) ──────────────────────────────────────
Write-LogHost 'Checking data directories for cleanup...' -Color Cyan
Write-Log "Uninstallation complete. Checking data directories for cleanup."

foreach ($dir in @($Script:DataDir, $Script:LegacyDataDir)) {
    if (Test-Path -LiteralPath $dir) {
        $logFile  = Join-Path $dir 'logs\uninstall.log'
        $remaining = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $logFile })
        if ($remaining.Count -eq 0) {
            try {
                Remove-Item -LiteralPath $dir -Recurse -Force
                Write-Host "  Data directory removed: $dir" -ForegroundColor Green
            } catch {
                Write-Host "  WARNING: Could not remove: $dir" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Data directory not empty — left in place: $dir" -ForegroundColor Yellow
        }
    }
}
#endregion

#region ── Summary ───────────────────────────────────────────────────────────────
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Green
Write-Host ' hellosudo uninstallation complete.' -ForegroundColor Green
Write-Host ('=' * 60) -ForegroundColor Green
#endregion
