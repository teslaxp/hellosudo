#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs hellosudo — Biometric-first UAC elevation for Windows 11 local accounts.

.DESCRIPTION
    Dynamically toggles the 'Disabled' DWORD value of the PasswordProvider GUID so that 
    ConsentUI (UAC window) displays biometrics/PIN immediately, instead of hiding it 
    behind the "More choices" button.

    As a mandatory core step, the installer also configures the UAC prompt policy 
    for Administrators to require explicit authentication (biometric or PIN) on the Secure Desktop:
      - ConsentPromptBehaviorAdmin = 1  (prompts for credentials, not just consent)
      - PromptOnSecureDesktop      = 1  (always uses the isolated Secure Desktop)
    
    Original values are preserved in registry metadata and fully restored by the uninstaller.

.PARAMETER Quiet
    Skips the interactive "Review & Confirm" menu. Ideal for automation.
    Alias: Silent.

.PARAMETER SkipSudo
    Skips the configuration of the native Windows 'sudo' command.
    Alias: NoSudo.

.PARAMETER SudoMode
    Defines the sudo mode (normal, forceNewWindow, disableInput). 
    Only effective if -SkipSudo is not used. Requires Windows 11 24H2 or later.

.PARAMETER Triggers
    Defines which system events should trigger the scheduled tasks.
    Accepts: Lock, Unlock, Logon, Logoff, Startup.

.PARAMETER GpoScripts
    Defines which Group Policy Object (GPO) script phases hellosudo should hook into.
    Accepts: Startup, Shutdown. Silently ignored on Windows Home editions.

.PARAMETER PasswordProviderGuid
    The GUID of the Password Credential Provider. 
    Default: {60b78e88-ead8-445c-9cfd-0b87f74ea6cd}.

.PARAMETER SkipHelloCheck
    Bypasses the Windows Hello PIN/Biometric safety check.
    WARNING: Using this without a configured PIN may lead to total UAC lockout.

.EXAMPLE
    .\install.ps1
    Interactive installation with default settings.

.EXAMPLE
    .\install.ps1 -Quiet -Triggers Lock,Unlock,Logon -GpoScripts Shutdown
    Silent installation with specific triggers.

.EXAMPLE
    .\install.ps1 -Quiet -SkipSudo
    Silent installation without modifying Windows sudo settings.

.EXAMPLE
    .\install.ps1 -Quiet -SkipHelloCheck
    Silent installation bypassing the biometric pre-flight check.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [alias('Silent', 'q')]
    [switch]$Quiet,

    [alias('NoHelloCheck','nohc')]
    [switch]$SkipHelloCheck,

    [alias('NoSudo','nosd')]
    [switch]$SkipSudo,

    [ValidateSet('normal', 'forceNewWindow', 'disableInput')]
    [alias('sm')]
    [string]$SudoMode = 'normal',

    [ValidateSet('Lock', 'Unlock', 'Logon', 'Logoff', 'Startup')]
    [alias('Tasks', 'tgs')]
    [string[]]$Triggers = @('Lock', 'Unlock', 'Logon', 'Logoff', 'Startup'),

    [ValidateSet('Startup', 'Shutdown')]
    [alias('GPScripts', 'Scripts', 'gps')]
    [string[]]$GpoScripts = @('Shutdown'),

    [alias('pwid', 'pwdguid')]
    [guid]$PasswordProviderGuid = '{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Constants ────────────────────────────────────────────────────────────
$Script:LogDir = 'C:\ProgramData\hellosudo\logs'
$Script:LogFile = Join-Path $Script:LogDir 'install.log'
$Script:ProgramDir = 'C:\ProgramData\hellosudo'
$Script:LauncherName = 'hellosudo.cmd'
$Script:MetaKey = 'HKLM:\SOFTWARE\hellosudo'
$Script:GuidStr = $PasswordProviderGuid.ToString('B')  # Format with braces for registry key paths
$Script:CPKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$Script:GuidStr"
$Script:UACPolicyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$Script:TaskPath = '\hellosudo\'
$Script:TaskDisable = 'hellosudo_Disable_Password'
$Script:TaskRestore = 'hellosudo_Restore_Password'
$Script:RegExe = "$env:SystemRoot\System32\reg.exe"
$Script:GPIniPath = "$env:SystemRoot\System32\GroupPolicy\Machine\Scripts\scripts.ini"
$Script:Silent = $Quiet.IsPresent -or $false -eq $PSBoundParameters['Confirm']
$Script:EnableSudo = -not $SkipSudo.IsPresent
#endregion

#region ── Logging ──────────────────────────────────────────────────────────────
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if (-not (Test-Path $Script:LogDir)) {
        $null = New-Item -ItemType Directory -Path $Script:LogDir -Force
    }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $Script:LogFile -Value "[$timestamp] [$Level] $Message" -Encoding UTF8

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
#endregion

#region ── Log Banner ────────────────────────────────────────────────────────────
Write-LogHost ('=' * 60) -Color Cyan
Write-LogHost ' hellosudo  —  Biometric-First UAC Installer' -Color Cyan
Write-LogHost ('=' * 60) -Color Cyan
Write-Log "Script path   : $($MyInvocation.PSCommandPath)"
Write-Log "PowerShell    : $($PSVersionTable.PSVersion)"
Write-Log "Triggers param   : $($Triggers -join ', ')"
Write-Log "GpoScripts     : $($GpoScripts -join ', ')"
Write-Log "ProviderGUID  : $script:GuidStr"
Write-Log "Silent        : $Silent"
Write-Log "IgnoreHello   : $SkipHelloCheck"
Write-Log "EnableSudo    : $EnableSudo"
Write-Log "SudoMode      : $SudoMode"
#endregion

#region ── OS Edition Guard ─────────────────────────────────────────────────────
$osInfo    = Get-CimInstance Win32_OperatingSystem
$osCaption = $osInfo.Caption
Write-Log "OS detected   : $osCaption"

$isHomeEdition = $osCaption -match '\bHome\b'
if ($isHomeEdition -and $GpoScripts.Count -gt 0) {
    Write-LogHost "WARNING: OS appears to be a Home edition ('$osCaption'). Local GPO is not supported. GPO script configuration will be skipped." -Level WARN -Color Yellow
    $GpoScripts = @()
}
#endregion

#region ── Windows Hello / NGC Pre-flight Check ──────────────────────────────────
function Test-NgcPinConfigured {
    <#
    .SYNOPSIS
        Returns $true if at least one NGC (PIN/Windows Hello) credential entry
        exists on this machine, indicating that biometric/PIN auth is available.
    .NOTES
        The NGC credentials key contains one subkey per enrolled credential.
        An empty key (no children) means Windows Hello / PIN is not set up.
    #>
    $ngcKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\NgcPin\Credentials'
    if (-not (Test-Path $ngcKey)) { return $false }
    $children = @(Get-ChildItem -Path $ngcKey -ErrorAction SilentlyContinue)
    return ($children.Count -gt 0)
}

Write-LogHost 'Running Windows Hello / NGC pre-flight check...' -Color Cyan
$helloConfigured = Test-NgcPinConfigured
Write-Log "NGC/Hello credentials detected: $helloConfigured"

if (-not $helloConfigured -and -not $SkipHelloCheck) {
    if ($Silent) {
        # Hard terminating error — cannot prompt in silent mode
        $errMsg = @(
            'SAFETY ABORT: No Windows Hello PIN or Biometric credential was detected on this system.'
            'Disabling the PasswordProvider without an alternative credential provider will leave'
            'ConsentUI with no available sign-in option, effectively locking out all UAC elevations.'
            ''
            'Resolution options:'
            '  1. Configure a Windows Hello PIN or Biometrics (Settings > Accounts > Sign-in options)'
            '     then re-run the installer.'
            '  2. If you are certain a credential provider IS available and want to bypass this guard,'
            '     re-run with: .\install.ps1 -Silent -SkipHelloCheck'
        ) -join [Environment]::NewLine
        Write-Log $errMsg -Level ERROR
        throw $errMsg
    } else {
        # Interactive warning — require explicit "PROCEED" confirmation
        Write-Host ''
        Write-Host ('!' * 62) -ForegroundColor Red
        Write-Host '!!                  *** SAFETY WARNING ***                  !!' -ForegroundColor Red
        Write-Host ('!' * 62) -ForegroundColor Red
        Write-Host '' 
        Write-Host '  No Windows Hello PIN or Biometric credential was detected.' -ForegroundColor Red
        Write-Host '' 
        Write-Host '  hellosudo works by DISABLING the PasswordProvider credential' -ForegroundColor Yellow
        Write-Host '  provider. If no alternative provider (PIN, fingerprint, face)' -ForegroundColor Yellow
        Write-Host '  is configured, ConsentUI will have ZERO available options.' -ForegroundColor Yellow
        Write-Host '  This will make it IMPOSSIBLE to approve UAC prompts.' -ForegroundColor Yellow
        Write-Host '' 
        Write-Host '  Recommended action:' -ForegroundColor Cyan
        Write-Host '    Settings > Accounts > Sign-in options > Windows Hello PIN' -ForegroundColor Cyan
        Write-Host '    Set up a PIN first, then re-run this installer.' -ForegroundColor Cyan
        Write-Host '' 
        Write-Host ('!' * 62) -ForegroundColor Red
        Write-Host ''

        $confirmation = Read-Host 'Type PROCEED to bypass this safety check, or press Enter to abort'
        if ($confirmation.Trim() -ne 'PROCEED') {
            Write-LogHost 'Installation aborted by user at safety check.' -Color Yellow
            exit 0
        }
        Write-Log 'User explicitly typed PROCEED to bypass Hello pre-flight check.'
        Write-LogHost 'Safety check bypassed by user confirmation.' -Level WARN -Color Yellow
    }
} elseif (-not $helloConfigured -and $SkipHelloCheck) {
    Write-LogHost 'WARNING: No NGC/Hello credentials detected, but -SkipHelloCheck was specified. Proceeding.' -Level WARN -Color Yellow
    Write-Log 'Hello check bypassed via -SkipHelloCheck flag.'
} else {
    Write-LogHost '  Windows Hello / PIN credential confirmed — safe to proceed.' -Color Green
}
#endregion

#region ── Interactive Review & Confirm ─────────────────────────────────────────
if (-not $Silent) {
    Write-Host ''
    Write-Host '╔══════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '║       hellosudo  ·  Review & Confirm Installation        ║' -ForegroundColor Cyan
    Write-Host '╠══════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host "║  Provider GUID : $script:GuidStr" -ForegroundColor White
    Write-Host "║  Triggers         : $($Triggers -join ', ')" -ForegroundColor White
    Write-Host "║  GPO Scripts   : $(if ($GpoScripts.Count) { $GpoScripts -join ', ' } else { '(none)' })" -ForegroundColor White
    Write-Host "║  Enable Sudo   : $EnableSudo" -ForegroundColor White
    Write-Host "║  Sudo Mode     : $SudoMode" -ForegroundColor White
    Write-Host '║  UAC Policy    : ConsentPromptBehaviorAdmin=1,            ' -ForegroundColor White
    Write-Host '║                  PromptOnSecureDesktop=1 (core/mandatory) ' -ForegroundColor White
    Write-Host '╠═══════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '║  [Y] Accept default settings and continue                 ║' -ForegroundColor Green
    Write-Host '║  [T] Change Triggers selection                               ║' -ForegroundColor Yellow
    Write-Host '║  [G] Change GPO Scripts selection                         ║' -ForegroundColor Yellow
    Write-Host '║  [S] Change Sudo settings                                 ║' -ForegroundColor Yellow
    Write-Host '║  [Q] Quit                                                 ║' -ForegroundColor Red
    Write-Host '╚═══════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''

    $validTriggers      = @('Lock', 'Unlock', 'Logon', 'Logoff', 'Startup')
    $validGpoScripts  = @('Startup', 'Shutdown')

    :menuLoop while ($true) {
        $choice = Read-Host 'Your choice'
        switch ($choice.Trim().ToUpper()) {
            'Y' { break menuLoop }
            'Q' { Write-LogHost 'Installation cancelled by user.' -Color Yellow; exit 0 }
            'T' {
                Write-Host "Available Triggers: $($validTriggers -join ', ')" -ForegroundColor Cyan
                $raw    = Read-Host 'Enter comma-separated Triggers (or press Enter to keep current)'
                if ($raw.Trim() -ne '') {
                    $chosen = $raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -in $validTriggers }
                    if ($chosen.Count -eq 0) {
                        Write-Host 'No valid Triggers recognised, keeping current selection.' -ForegroundColor Yellow
                    } else {
                        $Triggers = $chosen
                        Write-Host "Triggers updated to: $($Triggers -join ', ')" -ForegroundColor Green
                        Write-Log "Triggers updated interactively to: $($Triggers -join ', ')"
                    }
                }
            }
            'G' {
                if ($isHomeEdition) {
                    Write-Host 'GPO scripts are not available on this Home edition.' -ForegroundColor Yellow
                } else {
                    Write-Host "Available GP scripts: $($validGpoScripts -join ', ')" -ForegroundColor Cyan
                    $raw    = Read-Host 'Enter comma-separated GPO scripts (or press Enter to keep current; leave blank to disable)'
                    $chosen = $raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -in $validGpoScripts }
                    $GpoScripts = $chosen
                    Write-Host "GPO Scripts updated to: $(if ($GpoScripts.Count) { $GpoScripts -join ', ' } else { '(none)' })" -ForegroundColor Green
                    Write-Log "GpoScripts updated interactively to: $($GpoScripts -join ', ')"
                }
            }
            'S' {
                $raw = Read-Host 'Enable Windows sudo during install? (yes/no)'
                if ($raw.Trim().ToLower() -in @('yes','y')) { $EnableSudo = $true }
                elseif ($raw.Trim().ToLower() -in @('no','n')) { $EnableSudo = $false }

                if ($EnableSudo) {
                    Write-Host 'Available modes: normal, forceNewWindow, disableInput' -ForegroundColor Cyan
                    $modeInput = (Read-Host 'Sudo mode (or press Enter for normal)').Trim()
                    if ($modeInput -in @('normal','forceNewWindow','disableInput')) {
                        $SudoMode = $modeInput
                    }
                }
                Write-Log "Sudo settings updated interactively: EnableSudo=$EnableSudo, SudoMode=$SudoMode"
            }
            default { Write-Host 'Invalid choice, please enter Y, T, G, S, or Q.' -ForegroundColor Red }
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
$originalConsentBehavior = 5
$originalSecureDesktop   = 1

# Idempotent install behavior:
# - If metadata already exists, reuse the originally captured values.
# - If metadata does not exist, capture values from the live system.
if (Test-Path $Script:MetaKey) {
    Write-LogHost "Metadata key already exists at '$($Script:MetaKey)'. Reusing previously stored original values..." -Color Cyan
    try {
        $metaProps = Get-ItemProperty -Path $Script:MetaKey -ErrorAction Stop

        if ($metaProps.PSObject.Properties['OriginalDisabledExisted']) {
            $originalDisabledExisted = [bool]([int]$metaProps.OriginalDisabledExisted)
        } else {
            Write-Log "Missing metadata property 'OriginalDisabledExisted'; using default '$originalDisabledExisted'." -Level WARN
        }

        if ($metaProps.PSObject.Properties['OriginalDisabledState']) {
            $originalDisabledState = [int]$metaProps.OriginalDisabledState
        } else {
            Write-Log "Missing metadata property 'OriginalDisabledState'; using default '$originalDisabledState'." -Level WARN
        }

        if ($metaProps.PSObject.Properties['OriginalConsentBehavior']) {
            $originalConsentBehavior = [int]$metaProps.OriginalConsentBehavior
        } else {
            Write-Log "Missing metadata property 'OriginalConsentBehavior'; using default '$originalConsentBehavior'." -Level WARN
        }

        if ($metaProps.PSObject.Properties['OriginalSecureDesktop']) {
            $originalSecureDesktop = [int]$metaProps.OriginalSecureDesktop
        } else {
            Write-Log "Missing metadata property 'OriginalSecureDesktop'; using default '$originalSecureDesktop'." -Level WARN
        }
    } catch {
        Write-Log "Failed to read existing metadata key '$($Script:MetaKey)': $_" -Level WARN
        Write-Log "Falling back to defaults for original state values to avoid capturing already-modified live values." -Level WARN
    }
} else {
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
}

Write-Log "OriginalDisabledExisted      : $([int]$originalDisabledExisted)"
Write-Log "OriginalDisabledState        : $originalDisabledState"
Write-Log "OriginalConsentBehavior      : $originalConsentBehavior"
Write-Log "OriginalSecureDesktop        : $originalSecureDesktop"
#endregion

#region ── Write Metadata ────────────────────────────────────────────────────────
Write-LogHost 'Writing installation metadata to HKLM:\SOFTWARE\hellosudo ...' -Color Cyan

if ($PSCmdlet.ShouldProcess($Script:MetaKey, 'Create/update metadata registry key')) {
    if (-not (Test-Path $Script:MetaKey)) {
        New-Item -Path $Script:MetaKey -Force | Out-Null
    }
    Set-ItemProperty -Path $Script:MetaKey -Name 'TargetGUID'              -Value $Script:GuidStr          -Type String
    Set-ItemProperty -Path $Script:MetaKey -Name 'OriginalDisabledExisted' -Value ([int]$originalDisabledExisted) -Type DWord
    Set-ItemProperty -Path $Script:MetaKey -Name 'OriginalDisabledState'   -Value $originalDisabledState          -Type DWord
    Set-ItemProperty -Path $Script:MetaKey -Name 'InstalledTriggers'          -Value ($Triggers -join ',')             -Type String
    Set-ItemProperty -Path $Script:MetaKey -Name 'InstalledGpoScripts'      -Value ($GpoScripts -join ',')         -Type String
    Set-ItemProperty -Path $Script:MetaKey -Name 'OriginalConsentBehavior' -Value $originalConsentBehavior       -Type DWord
    Set-ItemProperty -Path $Script:MetaKey -Name 'OriginalSecureDesktop'   -Value $originalSecureDesktop         -Type DWord

    Write-Log "Metadata written: TargetGUID=$Script:GuidStr, OriginalDisabledExisted=$([int]$originalDisabledExisted), OriginalDisabledState=$originalDisabledState, InstalledTriggers=$($Triggers -join ','), InstalledGpoScripts=$($GpoScripts -join ','), OriginalConsentBehavior=$originalConsentBehavior, OriginalSecureDesktop=$originalSecureDesktop"
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
    $keyPath = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$Script:GuidStr"
    return "ADD `"$keyPath`" /v Disabled /t REG_DWORD /d $Value /f"
}
#endregion

#region ── Task Scheduler ────────────────────────────────────────────────────────
Write-LogHost 'Configuring scheduled tasks...' -Color Cyan

# Build the raw registry key path used inside reg.exe arguments
$Script:CPKeyRaw = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$Script:GuidStr"

# XML-escape helper — needed for embedding values inside Task XML strings.
# Using XML avoids PSTypeName mismatches when mixing trigger types in PS5.1:
# New-CimInstance -ClientOnly omits parent-class PSTypeNames (e.g. MSFT_TaskTrigger),
# causing New-ScheduledTask -Trigger to reject the objects.
function ConvertTo-XmlString { param([string]$s)
    $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'","&apos;"
}

function New-HellosudoTaskXml {
    <#
    .SYNOPSIS
        Returns a Task Scheduler XML string for a hellosudo task.
    .PARAMETER TriggerXml
        Array of pre-formed XML trigger element strings.
    .PARAMETER ActionArgs
        Arguments to pass to reg.exe. Will be XML-escaped automatically.
    .PARAMETER Description
        Human-readable task description.
    #>
    [CmdletBinding()] param(
        [string[]]$TriggerXml,
        [string]$ActionArgs,
        [string]$Description
    )
    $triggersBlock = ($TriggerXml | ForEach-Object { "    $_" }) -join "`r`n"
    $escapedArgs   = ConvertTo-XmlString $ActionArgs
    $escapedDesc   = ConvertTo-XmlString $Description
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$escapedDesc</Description>
  </RegistrationInfo>
  <Triggers>
$triggersBlock
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$($Script:RegExe)</Command>
      <Arguments>$escapedArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-HellosudoTask {
    [CmdletBinding(SupportsShouldProcess)] param(
        [string]$TaskName,
        [string]$Xml
    )
    if (Get-ScheduledTask -TaskName $TaskName -TaskPath $Script:TaskPath -ErrorAction SilentlyContinue) {
        Write-Log "Task '$TaskName' already exists — replacing."
        if ($PSCmdlet.ShouldProcess("$($Script:TaskPath)$TaskName", 'Unregister existing scheduled task')) {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath $Script:TaskPath -Confirm:$false
        }
    }
    if ($PSCmdlet.ShouldProcess("$($Script:TaskPath)$TaskName", 'Register scheduled task')) {
        Register-ScheduledTask -TaskName $TaskName -TaskPath $Script:TaskPath -Xml $Xml | Out-Null
        Write-LogHost "Registered task: $($Script:TaskPath)$TaskName" -Color Green
        Write-Log "Registered task: $($Script:TaskPath)$TaskName"
    }
}

# ── Task: hellosudo_Disable_Password (Disabled=1) ──────────────────────────────
$disableTriggerXml = @()

if ('Logon' -in $Triggers) {
    Write-Log "Adding Logon trigger to $($Script:TaskDisable)"
    $disableTriggerXml += '<LogonTrigger><Enabled>true</Enabled></LogonTrigger>'
}
if ('Unlock' -in $Triggers) {
    Write-Log "Adding Workstation Unlock trigger to $($Script:TaskDisable)"
    $disableTriggerXml += '<SessionStateChangeTrigger><StateChange>SessionUnlock</StateChange><Enabled>true</Enabled></SessionStateChangeTrigger>'
}

if ($disableTriggerXml.Count -gt 0) {
    $disableArgs = "ADD `"$($Script:CPKeyRaw)`" /v Disabled /t REG_DWORD /d 1 /f"
    $disableXml  = New-HellosudoTaskXml -TriggerXml $disableTriggerXml -ActionArgs $disableArgs `
                       -Description 'hellosudo: Suppresses PasswordProvider on logon/unlock — biometrics and PIN surface first in UAC.'
    Register-HellosudoTask -TaskName $Script:TaskDisable -Xml $disableXml
} else {
    Write-Log "No triggers selected for '$($Script:TaskDisable)' — skipping registration."
}

# ── Task: hellosudo_Restore_Password (Disabled=0) ──────────────────────────────
$restoreTriggerXml = @()

if ('Startup' -in $Triggers) {
    Write-Log "Adding Startup trigger to $($Script:TaskRestore)"
    $restoreTriggerXml += '<BootTrigger><Enabled>true</Enabled></BootTrigger>'
}
if ('Lock' -in $Triggers) {
    Write-Log "Adding Workstation Lock trigger to $($Script:TaskRestore)"
    $restoreTriggerXml += '<SessionStateChangeTrigger><StateChange>SessionLock</StateChange><Enabled>true</Enabled></SessionStateChangeTrigger>'
}
if ('Logoff' -in $Triggers) {
    Write-Log "Adding Logoff (Event 7002) trigger to $($Script:TaskRestore)"
    # The subscription XML must be entity-encoded when embedded inside the outer Task XML
    $logoffSubscription = ConvertTo-XmlString (
        '<QueryList><Query Id="0" Path="System">' +
        '<Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Winlogon''] and EventID=7002]]</Select>' +
        '</Query></QueryList>'
    )
    $restoreTriggerXml += "<EventTrigger><Enabled>true</Enabled><Subscription>$logoffSubscription</Subscription></EventTrigger>"
}

if ($restoreTriggerXml.Count -gt 0) {
    $restoreArgs = "ADD `"$($Script:CPKeyRaw)`" /v Disabled /t REG_DWORD /d 0 /f"
    $restoreXml  = New-HellosudoTaskXml -TriggerXml $restoreTriggerXml -ActionArgs $restoreArgs `
                       -Description 'hellosudo: Restores PasswordProvider on startup/lock/logoff — preserves standard credential flow.'
    Register-HellosudoTask -TaskName $Script:TaskRestore -Xml $restoreXml
} else {
    Write-Log "No triggers selected for '$($Script:TaskRestore)' — skipping registration."
}
#endregion

#region ── GPO Scripts ───────────────────────────────────────────────────────────
function Update-GpoIni {
    <#
    .SYNOPSIS
        Safely appends a hellosudo block to the GPO scripts.ini file without
        corrupting existing third-party sections.
    .NOTES
        Internal helper — no SupportsShouldProcess. The calling code is responsible
        for WhatIf/Confirm decisions. Removing CmdletBinding here eliminates the
        $PSCmdlet.ShouldProcess() call that caused the script to hang waiting for
        console input in non-interactive sudo sessions.
        Uses ArrayList throughout for reliable .Count under Set-StrictMode -Version Latest.
        Uses -LiteralPath to avoid wildcard expansion on bracket chars.
    #>
    param(
        [Parameter(Mandatory)][string]$IniPath,
        [Parameter(Mandatory)][string]$Section,        # e.g. 'Shutdown'
        [Parameter(Mandatory)][int]   $DisabledValue
    )

    $keyPath       = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$Script:GuidStr"
    $cmdLine       = $Script:RegExe
    $cmdArgs       = "ADD `"$keyPath`" /v Disabled /t REG_DWORD /d $DisabledValue /f"
    $marker        = '# hellosudo'
    $sectionHeader = "[$Section]"

    $dir = Split-Path $IniPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Created GPO scripts directory: $dir"
    }

    # Load file into an ArrayList — .Count is a native .NET property and is
    # always available regardless of PS version or strict mode setting.
    $lines = [System.Collections.ArrayList]::new()
    if (Test-Path -LiteralPath $IniPath) {
        foreach ($line in (Get-Content -LiteralPath $IniPath -Encoding Unicode)) {
            [void]$lines.Add($line)
        }
    }
    Write-Log "Update-GpoIni: loaded $($lines.Count) line(s) from '$IniPath' for section [$Section]"

    # Idempotency: skip if our marker already exists anywhere in the file
    if ($lines.Contains($marker)) {
        Write-Log "GPO ini '$IniPath' already contains hellosudo block — skipping."
        return
    }

    # Locate the [Section] header; if missing, append it with a blank separator
    $sectionIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq $sectionHeader) { $sectionIdx = $i; break }
    }
    if ($sectionIdx -eq -1) {
        [void]$lines.Add('')
        [void]$lines.Add($sectionHeader)
        $sectionIdx = $lines.Count - 1
    }

    # Determine next script index scoped to the target section only.
    # Scanning globally would contaminate numbering when [Startup] and [Shutdown]
    # both exist in the same scripts.ini file.
    $nextIdx = 0
    for ($i = $sectionIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[') { break }            # hit next section — stop
        if ($lines[$i] -match '^(\d+)CmdLine=') {
            $candidate = [int]$Matches[1] + 1
            if ($candidate -gt $nextIdx) { $nextIdx = $candidate }
        }
    }

    # Find insertion point: end of the target section (before the next section header)
    $insertAt = $sectionIdx + 1
    for ($i = $sectionIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[') { break }
        $insertAt = $i + 1
    }

    # Insert the three new lines in order (Insert shifts existing items down)
    [void]$lines.Insert($insertAt,     "${nextIdx}CmdLine=$cmdLine")
    [void]$lines.Insert($insertAt + 1, "${nextIdx}Parameters=$cmdArgs")
    [void]$lines.Insert($insertAt + 2, $marker)

    Set-Content -LiteralPath $IniPath -Value $lines.ToArray() -Encoding Unicode
    Write-Log "Updated GPO ini '$IniPath' — added [$Section] block at index $nextIdx."
}

$gpupdateNeeded = $false

if ('Shutdown' -in $GpoScripts) {
    Write-LogHost 'Configuring GPO Shutdown script...' -Color Cyan
    Update-GpoIni -IniPath $Script:GPIniPath -Section 'Shutdown' -DisabledValue 0
    $gpupdateNeeded = $true
}

if ('Startup' -in $GpoScripts) {
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

#region ── Windows Sudo Enablement ──────────────────────────────────────────────
if ($EnableSudo) {
    Write-LogHost 'Configuring Windows sudo...' -Color Cyan

    $sudoExe = Get-Command sudo -CommandType Application -ErrorAction SilentlyContinue
    if (-not $sudoExe) {
        Write-Log 'sudo.exe not found — Windows sudo requires Windows 11 24H2 or later.' -Level WARN
        Write-LogHost '  WARNING: sudo.exe not found on this system.' -Level WARN -Color Yellow
        Write-LogHost '  Windows sudo requires Windows 11 24H2+. Skipping sudo configuration.' -Color Yellow
    } else {
        try {
            $sudoOut = & sudo config --enable $SudoMode 2>&1
            Write-Log "sudo config --enable $SudoMode : $($sudoOut -join ' ')"
            Write-LogHost "  Windows sudo enabled (mode: $SudoMode)." -Color Green

            # Verify the registry confirms enablement
            $sudoReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' `
                           -Name 'Enabled' -ErrorAction SilentlyContinue
            if ($null -ne $sudoReg -and [int]$sudoReg.Enabled -ge 1) {
                Write-Log "Sudo registry confirmed enabled (Enabled=$($sudoReg.Enabled))."
            } else {
                Write-Log 'Sudo registry value not confirmed — sudo config may require a newer OS build.' -Level WARN
            }
        } catch {
            Write-Log "sudo config failed: $_" -Level WARN
            Write-LogHost '  WARNING: Could not configure Windows sudo.' -Level WARN -Color Yellow
            Write-LogHost '  Installation will continue without sudo configuration.' -Color Yellow
        }
    }
} else {
    Write-Log "Windows sudo configuration skipped (-EnableSudo:$false)."
    Write-LogHost '  Windows sudo configuration skipped.' -Color Yellow
}
#endregion

#region ── CLI Launcher Deployment (Program Folder + PATH) ─────────────────────
Write-LogHost 'Installing hellosudo launcher and updating PATH...' -Color Cyan

$scriptRoot = $null
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $scriptRoot = $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    $scriptRoot = Split-Path -Path $PSCommandPath -Parent
} elseif ($null -ne $MyInvocation.MyCommand -and -not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    $scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
}

if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    throw 'Unable to resolve installer directory for launcher deployment (script path is unavailable).'
}

$launcherSource = Join-Path $scriptRoot $Script:LauncherName
$launcherTarget = Join-Path $Script:ProgramDir $Script:LauncherName

if (-not (Test-Path -LiteralPath $launcherSource)) {
    throw "Launcher source not found: $launcherSource"
}

if ($PSCmdlet.ShouldProcess($Script:ProgramDir, 'Create program folder for hellosudo launcher')) {
    if (-not (Test-Path -LiteralPath $Script:ProgramDir)) {
        New-Item -ItemType Directory -Path $Script:ProgramDir -Force | Out-Null
        Write-Log "Created program folder: $Script:ProgramDir"
    }
}

if ($PSCmdlet.ShouldProcess($launcherTarget, 'Copy hellosudo launcher')) {
    Copy-Item -LiteralPath $launcherSource -Destination $launcherTarget -Force
    Write-Log "Launcher copied to: $launcherTarget"
}

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$pathParts = @()
if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
    $pathParts = @($machinePath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$programDirCompare = $Script:ProgramDir.Trim().TrimEnd('\\')
$existsInMachinePath = $false
foreach ($part in $pathParts) {
    if ($part.Trim().TrimEnd('\\') -ieq $programDirCompare) {
        $existsInMachinePath = $true
        break
    }
}

if (-not $existsInMachinePath) {
    $newMachinePath = if ([string]::IsNullOrWhiteSpace($machinePath)) {
        $Script:ProgramDir
    } else {
        "$machinePath;$($Script:ProgramDir)"
    }

    if ($PSCmdlet.ShouldProcess('HKLM Path environment variable', "Append '$($Script:ProgramDir)'")) {
        [Environment]::SetEnvironmentVariable('Path', $newMachinePath, 'Machine')
        Write-Log "Added '$($Script:ProgramDir)' to machine PATH."
    }
} else {
    Write-Log "Machine PATH already contains '$($Script:ProgramDir)'."
}

# Keep the current process PATH aligned so launcher works immediately in this session.
$processPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
$processParts = @()
if (-not [string]::IsNullOrWhiteSpace($processPath)) {
    $processParts = @($processPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$existsInProcessPath = $false
foreach ($part in $processParts) {
    if ($part.Trim().TrimEnd('\\') -ieq $programDirCompare) {
        $existsInProcessPath = $true
        break
    }
}

if (-not $existsInProcessPath) {
    $newProcessPath = if ([string]::IsNullOrWhiteSpace($processPath)) {
        $Script:ProgramDir
    } else {
        "$processPath;$($Script:ProgramDir)"
    }
    [Environment]::SetEnvironmentVariable('Path', $newProcessPath, 'Process')
    Write-Log "Updated current process PATH with '$($Script:ProgramDir)'."
}
#endregion

#region ── Summary ───────────────────────────────────────────────────────────────
$sudoStatus = if ($EnableSudo) {
    $sr = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' `
              -Name 'Enabled' -ErrorAction SilentlyContinue
    if ($null -ne $sr -and [int]$sr.Enabled -ge 1) { "enabled ($SudoMode)" } else { 'configured (verify manually)' }
} else { 'skipped' }

Write-Host ''
Write-Host (' ' * 2 + 'hellosudo installed successfully.') -ForegroundColor White
Write-Host ''
Write-Host ('  [OK] Biometric-first UAC (ConsentPromptBehaviorAdmin=1)') -ForegroundColor Green
Write-Host ('  [OK] Secure Desktop enforced (PromptOnSecureDesktop=1)') -ForegroundColor Green
Write-Host ("  [OK] scheduled tasks registered in \hellosudo\") -ForegroundColor Green
Write-Host ("  [OK] launcher installed: $launcherTarget") -ForegroundColor Green
Write-Host ("  [OK] PATH contains: $($Script:ProgramDir)") -ForegroundColor Green
if ($GpoScripts.Count -gt 0) {
    Write-Host ("  [OK] GPO scripts configured ($($GpoScripts -join ', '))") -ForegroundColor Green
}
Write-Host ("  [OK] Windows sudo $sudoStatus") -ForegroundColor Green
Write-Host ('  [OK] Recovery metadata saved to HKLM:\SOFTWARE\hellosudo') -ForegroundColor Green
Write-Host ('  [OK] Logs: ' + $Script:LogFile) -ForegroundColor Green
Write-Host ''
Write-LogHost ('=' * 60) -Color Green
Write-LogHost ' hellosudo installation complete.' -Color Green
Write-LogHost ('=' * 60) -Color Green
#endregion
