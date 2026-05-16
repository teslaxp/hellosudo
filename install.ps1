#Requires -Version 5.1
<#
.SYNOPSIS
    Installs uacbio — a Windows UAC biometric fix for local accounts.

.DESCRIPTION
    Dynamically toggles the 'Disabled' DWORD of the PasswordProvider credential
    provider GUID so that ConsentUI surfaces biometrics immediately instead of
    hiding them behind "More choices".

    As a mandatory core step, the installer also configures the Administrator UAC
    prompt policy to require explicit credential (or biometric) authentication on
    the Secure Desktop by setting:
      - ConsentPromptBehaviorAdmin = 1  (prompt for credentials, not just consent)
      - PromptOnSecureDesktop       = 1  (always use the isolated Secure Desktop)
    Original values are preserved in metadata and fully restored on uninstall.

    Automation is achieved through Windows Task Scheduler triggers (Logon, Logoff,
    Lock, Unlock, Startup) and optional Group Policy startup/shutdown scripts.

.PARAMETER Silent
    Skip the interactive Review & Confirm menu.

.PARAMETER Tasks
    Which state-machine events to register as Scheduled Task triggers.
    Accepts any combination of: Lock, Unlock, Logon, Logoff, Startup.

.PARAMETER GPScripts
    Which Group Policy script phases to configure. Accepts: Startup, Shutdown.
    Silently skipped on Windows Home editions that do not support local GPO.

.PARAMETER PasswordProviderGUID
    Registry GUID of the PasswordProvider credential provider.
    Must include surrounding braces, e.g. {60b78e88-ead8-445c-9cfd-0b87f74ea6cd}.

.EXAMPLE
    .\install.ps1
    Interactive install using all defaults.

.EXAMPLE
    .\install.ps1 -Silent -Tasks Lock,Unlock,Logon -GPScripts Shutdown

.EXAMPLE
    .\install.ps1 -Tasks Logon,Unlock -GPScripts @() -Silent
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Silent,

    [ValidateSet('Lock', 'Unlock', 'Logon', 'Logoff', 'Startup')]
    [string[]]$Tasks = @('Lock', 'Unlock', 'Logon', 'Logoff', 'Startup'),

    [ValidateSet('Startup', 'Shutdown')]
    [string[]]$GPScripts = @('Shutdown'),

    [ValidatePattern('^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$')]
    [string]$PasswordProviderGUID = '{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Constants ────────────────────────────────────────────────────────────
$Script:LogDir      = 'C:\ProgramData\uacbio\logs'
$Script:LogFile     = Join-Path $Script:LogDir 'install.log'
$Script:MetaKey     = 'HKLM:\SOFTWARE\uacbio'
$Script:CPKey       = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$PasswordProviderGUID"
$Script:UACPolicyKey= 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$Script:TaskDisable = 'uacbio_Disable_Password'
$Script:TaskRestore = 'uacbio_Restore_Password'
$Script:RegExe      = "$env:SystemRoot\System32\reg.exe"
$Script:GPIniPath   = "$env:SystemRoot\System32\GroupPolicy\Machine\Scripts\scripts.ini"
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
    # Rebuild the argument list so we can forward all bound parameters
    $argList = @()
    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [switch]) {
            if ($val.IsPresent) { $argList += "-$key" }
        } elseif ($val -is [string[]]) {
            $argList += "-$key"
            $argList += ($val | ForEach-Object { "'$_'" }) -join ','
        } else {
            $argList += "-$key '$val'"
        }
    }
    $joined = $argList -join ' '
    $pwsh   = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }

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
        & sudo $pwsh -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $joined
    } else {
        Write-Host 'Elevating via Start-Process RunAs...' -ForegroundColor Cyan
        Start-Process -FilePath $pwsh `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" $joined" `
            -Verb RunAs
    }
    exit 0
}

if (-not (Test-IsAdmin)) { Invoke-SelfElevate }
#endregion

#region ── Log Banner ────────────────────────────────────────────────────────────
Write-LogHost ('=' * 60) -Color Cyan
Write-LogHost ' uacbio  —  Installation Script' -Color Cyan
Write-LogHost ('=' * 60) -Color Cyan
Write-Log "Script path   : $($MyInvocation.PSCommandPath)"
Write-Log "PowerShell    : $($PSVersionTable.PSVersion)"
Write-Log "Tasks param   : $($Tasks -join ', ')"
Write-Log "GPScripts     : $($GPScripts -join ', ')"
Write-Log "ProviderGUID  : $PasswordProviderGUID"
Write-Log "Silent        : $Silent"
#endregion

#region ── OS Edition Guard ─────────────────────────────────────────────────────
$osInfo    = Get-CimInstance Win32_OperatingSystem
$osCaption = $osInfo.Caption
Write-Log "OS detected   : $osCaption"

$isHomeEdition = $osCaption -match '\bHome\b'
if ($isHomeEdition -and $GPScripts.Count -gt 0) {
    Write-LogHost "WARNING: OS appears to be a Home edition ('$osCaption'). Local GPO is not supported. GPO script configuration will be skipped." -Level WARN -Color Yellow
    $GPScripts = @()
}
#endregion

#region ── Interactive Review & Confirm ─────────────────────────────────────────
if (-not $Silent) {
    Write-Host ''
    Write-Host '╔══════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '║          uacbio  ·  Review & Confirm Installation        ║' -ForegroundColor Cyan
    Write-Host '╠══════════════════════════════════════════════════════════╣' -ForegroundColor Cyan
    Write-Host "║  Provider GUID : $PasswordProviderGUID" -ForegroundColor White
    Write-Host "║  Tasks         : $($Tasks -join ', ')" -ForegroundColor White
    Write-Host "║  GPO Scripts   : $(if ($GPScripts.Count) { $GPScripts -join ', ' } else { '(none)' })" -ForegroundColor White
    Write-Host '║  UAC Policy    : ConsentPromptBehaviorAdmin=1,           ║' -ForegroundColor White
    Write-Host '║                  PromptOnSecureDesktop=1 (core/mandatory) ║' -ForegroundColor White
    Write-Host '╠══════════════════════════════════════════════════════════╣' -ForegroundColor Cyan
    Write-Host '║  [C] Continue with these settings                        ║' -ForegroundColor Green
    Write-Host '║  [T] Change Tasks selection                               ║' -ForegroundColor Yellow
    Write-Host '║  [G] Change GPO Scripts selection                         ║' -ForegroundColor Yellow
    Write-Host '║  [Q] Quit                                                 ║' -ForegroundColor Red
    Write-Host '╚══════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''

    $validTasks      = @('Lock', 'Unlock', 'Logon', 'Logoff', 'Startup')
    $validGPScripts  = @('Startup', 'Shutdown')

    :menuLoop while ($true) {
        $choice = Read-Host 'Your choice'
        switch ($choice.Trim().ToUpper()) {
            'C' { break menuLoop }
            'Q' { Write-LogHost 'Installation cancelled by user.' -Color Yellow; exit 0 }
            'T' {
                Write-Host "Available tasks: $($validTasks -join ', ')" -ForegroundColor Cyan
                $raw    = Read-Host 'Enter comma-separated tasks (or press Enter to keep current)'
                if ($raw.Trim() -ne '') {
                    $chosen = $raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -in $validTasks }
                    if ($chosen.Count -eq 0) {
                        Write-Host 'No valid tasks recognised, keeping current selection.' -ForegroundColor Yellow
                    } else {
                        $Tasks = $chosen
                        Write-Host "Tasks updated to: $($Tasks -join ', ')" -ForegroundColor Green
                        Write-Log "Tasks updated interactively to: $($Tasks -join ', ')"
                    }
                }
            }
            'G' {
                if ($isHomeEdition) {
                    Write-Host 'GPO scripts are not available on this Home edition.' -ForegroundColor Yellow
                } else {
                    Write-Host "Available GP scripts: $($validGPScripts -join ', ')" -ForegroundColor Cyan
                    $raw    = Read-Host 'Enter comma-separated GPO scripts (or press Enter to keep current; leave blank to disable)'
                    $chosen = $raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -in $validGPScripts }
                    $GPScripts = $chosen
                    Write-Host "GPO Scripts updated to: $(if ($GPScripts.Count) { $GPScripts -join ', ' } else { '(none)' })" -ForegroundColor Green
                    Write-Log "GPScripts updated interactively to: $($GPScripts -join ', ')"
                }
            }
            default { Write-Host 'Invalid choice, please enter C, T, G, or Q.' -ForegroundColor Red }
        }
    }
}
#endregion

#region ── Backup Current Registry State ────────────────────────────────────────
Write-LogHost 'Reading current PasswordProvider Disabled value...' -Color Cyan

# Track both existence and value independently so uninstall can make the right choice:
#   $originalDisabledExisted = $false → value was absent  → uninstall removes it
#   $originalDisabledExisted = $true  → value was present → uninstall restores it
$originalDisabledExisted = $false
$originalDisabledState   = 0

if (Test-Path $Script:CPKey) {
    try {
        $cpProps = Get-ItemProperty -Path $Script:CPKey -ErrorAction SilentlyContinue
        if ($null -ne $cpProps -and $cpProps.PSObject.Properties['Disabled']) {
            $originalDisabledExisted = $true
            $originalDisabledState   = [int]$cpProps.Disabled
            Write-Log "Current 'Disabled' value: $originalDisabledState (value present)"
        } else {
            Write-Log "'Disabled' value is absent — uninstall will remove it rather than set it to 0."
        }
    } catch {
        Write-Log "Could not read registry key '$($Script:CPKey)': $_" -Level WARN
    }
} else {
    Write-LogHost "Credential Provider registry key not found: $($Script:CPKey)" -Level WARN -Color Yellow
    Write-LogHost "The GUID may differ on this machine. Proceeding with no original value." -Level WARN -Color Yellow
}

# Read current UAC policy values before modifying them
Write-LogHost 'Reading current UAC policy values...' -Color Cyan
$uacPolicy = Get-ItemProperty -Path $Script:UACPolicyKey -ErrorAction SilentlyContinue
$originalConsentBehavior = if ($null -ne $uacPolicy -and $uacPolicy.PSObject.Properties['ConsentPromptBehaviorAdmin']) {
    [int]$uacPolicy.ConsentPromptBehaviorAdmin
} else {
    # Windows default: 5 (prompt for consent on secure desktop)
    5
}
$originalSecureDesktop = if ($null -ne $uacPolicy -and $uacPolicy.PSObject.Properties['PromptOnSecureDesktop']) {
    [int]$uacPolicy.PromptOnSecureDesktop
} else {
    # Windows default: 1 (secure desktop enabled)
    1
}
Write-Log "Current ConsentPromptBehaviorAdmin : $originalConsentBehavior"
Write-Log "Current PromptOnSecureDesktop      : $originalSecureDesktop"
#endregion

#region ── Write Metadata ────────────────────────────────────────────────────────
Write-LogHost 'Writing installation metadata to HKLM:\SOFTWARE\uacbio ...' -Color Cyan

if ($PSCmdlet.ShouldProcess($Script:MetaKey, 'Create/update metadata registry key')) {
    if (-not (Test-Path $Script:MetaKey)) {
        New-Item -Path $Script:MetaKey -Force | Out-Null
    }
    Set-ItemProperty -Path $Script:MetaKey -Name 'TargetGUID'              -Value $PasswordProviderGUID          -Type String
    Set-ItemProperty -Path $Script:MetaKey -Name 'OriginalDisabledExisted' -Value ([int]$originalDisabledExisted) -Type DWord
    Set-ItemProperty -Path $Script:MetaKey -Name 'OriginalDisabledState'   -Value $originalDisabledState          -Type DWord
    Set-ItemProperty -Path $Script:MetaKey -Name 'InstalledTasks'          -Value ($Tasks -join ',')             -Type String
    Set-ItemProperty -Path $Script:MetaKey -Name 'InstalledGPScripts'      -Value ($GPScripts -join ',')         -Type String
    Set-ItemProperty -Path $Script:MetaKey -Name 'OriginalConsentBehavior' -Value $originalConsentBehavior       -Type DWord
    Set-ItemProperty -Path $Script:MetaKey -Name 'OriginalSecureDesktop'   -Value $originalSecureDesktop         -Type DWord

    Write-Log "Metadata written: TargetGUID=$PasswordProviderGUID, OriginalDisabledExisted=$([int]$originalDisabledExisted), OriginalDisabledState=$originalDisabledState, InstalledTasks=$($Tasks -join ','), InstalledGPScripts=$($GPScripts -join ','), OriginalConsentBehavior=$originalConsentBehavior, OriginalSecureDesktop=$originalSecureDesktop"
}
#endregion

#region ── UAC Secure Desktop Policy ────────────────────────────────────────────
Write-LogHost 'Configuring UAC Secure Desktop credential policy (core)...' -Color Cyan

# ConsentPromptBehaviorAdmin = 1 : Prompt for credentials (enables biometric auth in ConsentUI)
# PromptOnSecureDesktop       = 1 : Always run the prompt on the isolated Secure Desktop
if ($PSCmdlet.ShouldProcess($Script:UACPolicyKey, 'Set ConsentPromptBehaviorAdmin = 1')) {
    Set-ItemProperty -Path $Script:UACPolicyKey -Name 'ConsentPromptBehaviorAdmin' -Value 1 -Type DWord
    Write-Log 'Set ConsentPromptBehaviorAdmin = 1 (credential prompt, triggers biometric flow).'
}

if ($PSCmdlet.ShouldProcess($Script:UACPolicyKey, 'Set PromptOnSecureDesktop = 1')) {
    Set-ItemProperty -Path $Script:UACPolicyKey -Name 'PromptOnSecureDesktop' -Value 1 -Type DWord
    Write-Log 'Set PromptOnSecureDesktop = 1 (Secure Desktop enforced).'
}

Write-LogHost '  UAC policy applied: credential prompt on Secure Desktop enabled.' -Color Green
#endregion

#region ── Helper: Registry action string ───────────────────────────────────────
function Get-RegAction {
    param([int]$Value)
    # Returns the reg.exe argument string to set Disabled to $Value
    $keyPath = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$PasswordProviderGUID"
    return "ADD `"$keyPath`" /v Disabled /t REG_DWORD /d $Value /f"
}
#endregion

#region ── Task Scheduler ────────────────────────────────────────────────────────
Write-LogHost 'Configuring scheduled tasks...' -Color Cyan

# Common principal — SYSTEM, highest available
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

# Common action builders
function New-RegAction {
    param([int]$DisabledValue)
    $keyPath = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$PasswordProviderGUID"
    $args    = "ADD `"$keyPath`" /v Disabled /t REG_DWORD /d $DisabledValue /f"
    return New-ScheduledTaskAction -Execute $Script:RegExe -Argument $args
}

# ── Task: uacbio_Disable_Password (Disabled=1) ──────────────────────────────
$disableTriggers = [System.Collections.Generic.List[CimInstance]]::new()

if ('Logon' -in $Tasks) {
    Write-Log "Adding Logon trigger to $($Script:TaskDisable)"
    $disableTriggers.Add((New-ScheduledTaskTrigger -AtLogOn))
}
if ('Unlock' -in $Tasks) {
    Write-Log "Adding Workstation Unlock trigger to $($Script:TaskDisable)"
    $unlockCim = New-CimInstance -Namespace 'Root\Microsoft\Windows\TaskScheduler' `
                    -ClassName 'MSFT_TaskSessionStateChangeTrigger' `
                    -ClientOnly `
                    -Property @{ StateChange = [uint32]8 }   # 8 = SessionUnlock
    $disableTriggers.Add($unlockCim)
}

if ($disableTriggers.Count -gt 0) {
    $action   = New-RegAction -DisabledValue 1
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    $taskDef  = New-ScheduledTask -Action $action -Principal $principal -Trigger $disableTriggers -Settings $settings `
                    -Description 'uacbio: Disables PasswordProvider so biometrics appear first in UAC.'

    if (Get-ScheduledTask -TaskName $Script:TaskDisable -ErrorAction SilentlyContinue) {
        Write-Log "Task '$($Script:TaskDisable)' already exists — replacing."
        if ($PSCmdlet.ShouldProcess($Script:TaskDisable, 'Unregister existing scheduled task')) {
            Unregister-ScheduledTask -TaskName $Script:TaskDisable -Confirm:$false
        }
    }
    if ($PSCmdlet.ShouldProcess($Script:TaskDisable, 'Register scheduled task')) {
        Register-ScheduledTask -TaskName $Script:TaskDisable -InputObject $taskDef | Out-Null
        Write-LogHost "Registered task: $($Script:TaskDisable)" -Color Green
    }
} else {
    Write-Log "No triggers selected for '$($Script:TaskDisable)' — skipping registration."
}

# ── Task: uacbio_Restore_Password (Disabled=0) ──────────────────────────────
$restoreTriggers = [System.Collections.Generic.List[CimInstance]]::new()

if ('Startup' -in $Tasks) {
    Write-Log "Adding Startup trigger to $($Script:TaskRestore)"
    $restoreTriggers.Add((New-ScheduledTaskTrigger -AtStartup))
}
if ('Lock' -in $Tasks) {
    Write-Log "Adding Workstation Lock trigger to $($Script:TaskRestore)"
    $lockCim = New-CimInstance -Namespace 'Root\Microsoft\Windows\TaskScheduler' `
                 -ClassName 'MSFT_TaskSessionStateChangeTrigger' `
                 -ClientOnly `
                 -Property @{ StateChange = [uint32]7 }   # 7 = SessionLock
    $restoreTriggers.Add($lockCim)
}
if ('Logoff' -in $Tasks) {
    Write-Log "Adding Logoff (Event 7002) trigger to $($Script:TaskRestore)"
    # Logoff via Event Log subscription: System log, Winlogon source, Event ID 7002
    $logoffXml = @'
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Winlogon'] and EventID=7002]]</Select>
  </Query>
</QueryList>
'@
    $logoffCim = New-CimInstance -Namespace 'Root\Microsoft\Windows\TaskScheduler' `
                     -ClassName 'MSFT_TaskEventTrigger' `
                     -ClientOnly `
                     -Property @{ Subscription = $logoffXml; Enabled = $true }
    $restoreTriggers.Add($logoffCim)
}

if ($restoreTriggers.Count -gt 0) {
    $action   = New-RegAction -DisabledValue 0
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    $taskDef  = New-ScheduledTask -Action $action -Principal $principal -Trigger $restoreTriggers -Settings $settings `
                    -Description 'uacbio: Restores PasswordProvider so the standard UAC flow is preserved outside elevated sessions.'

    if (Get-ScheduledTask -TaskName $Script:TaskRestore -ErrorAction SilentlyContinue) {
        Write-Log "Task '$($Script:TaskRestore)' already exists — replacing."
        if ($PSCmdlet.ShouldProcess($Script:TaskRestore, 'Unregister existing scheduled task')) {
            Unregister-ScheduledTask -TaskName $Script:TaskRestore -Confirm:$false
        }
    }
    if ($PSCmdlet.ShouldProcess($Script:TaskRestore, 'Register scheduled task')) {
        Register-ScheduledTask -TaskName $Script:TaskRestore -InputObject $taskDef | Out-Null
        Write-LogHost "Registered task: $($Script:TaskRestore)" -Color Green
    }
} else {
    Write-Log "No triggers selected for '$($Script:TaskRestore)' — skipping registration."
}
#endregion

#region ── GPO Scripts ───────────────────────────────────────────────────────────
function Update-GpoIni {
    <#
    .SYNOPSIS
        Safely appends a uacbio block to a GPO scripts .ini file without
        corrupting existing third-party sections.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$IniPath,
        [Parameter(Mandatory)][string]$Section,        # e.g. 'Shutdown'
        [Parameter(Mandatory)][int]   $DisabledValue
    )

    $keyPath  = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$PasswordProviderGUID"
    $cmdLine  = $Script:RegExe
    $cmdArgs  = "ADD `"$keyPath`" /v Disabled /t REG_DWORD /d $DisabledValue /f"

    $dir = Split-Path $IniPath -Parent
    if (-not (Test-Path $dir)) {
        if ($PSCmdlet.ShouldProcess($dir, 'Create GPO scripts directory')) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Log "Created GPO scripts directory: $dir"
        }
    }

    # Read existing content (or start fresh)
    $lines = if (Test-Path $IniPath) { Get-Content $IniPath -Encoding Unicode } else { @() }

    # Check if uacbio block is already present (idempotency guard)
    $marker = '# uacbio'
    if ($lines -contains $marker) {
        Write-Log "GPO ini '$IniPath' already contains uacbio block — skipping."
        return
    }

    # Locate the [Section] header; if missing, append it
    $sectionHeader = "[$Section]"
    $sectionLineNo = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq $sectionHeader) { $sectionLineNo = $i; break }
    }

    if ($null -eq $sectionLineNo) {
        # Section absent — append blank separator and header
        $lines       += ''
        $lines       += $sectionHeader
        $sectionLineNo = $lines.Count - 1   # 0-based index of the just-added header
    }

    # Determine the next available script index scoped to the target section only.
    # Scanning globally across sections would contaminate numbering when multiple
    # sections (e.g. [Startup] and [Shutdown]) both have entries.
    $nextIdx = 0
    for ($i = $sectionLineNo + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[') { break }   # hit next section header — stop
        if ($lines[$i] -match '^(\d+)CmdLine=') {
            $candidate = [int]$Matches[1] + 1
            if ($candidate -gt $nextIdx) { $nextIdx = $candidate }
        }
    }

    # Find insertion point: immediately after the last line of the target section
    $insertAt = $sectionLineNo + 1
    for ($i = $sectionLineNo + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[') { break }   # next section — stop before it
        $insertAt = $i + 1
    }

    # Build lines to insert
    $newLines = @(
        "${nextIdx}CmdLine=$cmdLine",
        "${nextIdx}Parameters=$cmdArgs",
        $marker
    )

    # Splice into array — guard the lower bound to avoid $lines[0..-1] on empty files
    $before = if ($insertAt -gt 0) { $lines[0..($insertAt - 1)] } else { @() }
    $after  = if ($insertAt -lt $lines.Count) { $lines[$insertAt..($lines.Count - 1)] } else { @() }
    $result = $before + $newLines + $after

    if ($PSCmdlet.ShouldProcess($IniPath, "Write GPO [$Section] script configuration")) {
        Set-Content -Path $IniPath -Value $result -Encoding Unicode
        Write-Log "Updated GPO ini '$IniPath' — added [$Section] block at index $nextIdx."
    }
}

$gpupdateNeeded = $false

if ('Shutdown' -in $GPScripts) {
    Write-LogHost 'Configuring GPO Shutdown script...' -Color Cyan
    Update-GpoIni -IniPath $Script:GPIniPath -Section 'Shutdown' -DisabledValue 0
    $gpupdateNeeded = $true
}

if ('Startup' -in $GPScripts) {
    Write-LogHost 'Configuring GPO Startup script...' -Color Cyan
    Update-GpoIni -IniPath $Script:GPIniPath -Section 'Startup' -DisabledValue 0
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

#region ── Summary ───────────────────────────────────────────────────────────────
Write-Host ''
Write-LogHost ('=' * 60) -Color Green
Write-LogHost ' uacbio installation complete!' -Color Green
Write-LogHost "  Log file : $($Script:LogFile)" -Color Green
Write-LogHost ('=' * 60) -Color Green
#endregion
