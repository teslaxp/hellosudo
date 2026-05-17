# hellosudo

**Biometric-first elevation for Windows 11 local accounts.**

---

## The Problem

On Windows 11 with a local account, UAC prompts show a password field by default. Windows Hello biometrics and PIN are hidden behind a "More choices" link — an extra friction point that breaks the fast-elevation workflow that Microsoft Account users get out of the box.

**Before hellosudo:**
```
UAC prompt → Password field → More choices → Fingerprint / PIN
```

**After hellosudo:**
```
UAC prompt → Fingerprint / PIN immediately
```

---

## How It Works

hellosudo configures two things:

**1. UAC credential policy (core — mandatory)**

Sets the Administrator consent prompt to require explicit credentials rather than a one-click consent:

| Registry value | Set to | Effect |
|---|---|---|
| `ConsentPromptBehaviorAdmin` | `1` | Credential prompt (enables biometric flow) |
| `PromptOnSecureDesktop` | `1` | Enforces the isolated Secure Desktop |

Both values are backed up during install and fully restored on uninstall.

This is the key unlock: when Windows prompts for credentials on the Secure Desktop, Windows Hello biometrics and PIN become the primary authentication options.

**2. PasswordProvider state machine (dynamic)**

The PasswordProvider (`{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}`) is the credential tile that shows a password field in ConsentUI. When it is present, it appears before biometric options. When its `Disabled` DWORD is set to `1`, it is hidden — and Windows Hello / PIN surfaces immediately.

hellosudo installs Task Scheduler jobs that toggle this value based on session state:

| Event | PasswordProvider | Reason |
|---|---|---|
| Logon / Unlock | `Disabled = 1` | Suppress password tile, surface biometrics |
| Lock / Logoff / Startup | `Disabled = 0` | Restore for standard flows |

This works on **both Windows Home and Pro** because it targets native registry keys directly, not Group Policy infrastructure.

---

## Quick Install

```powershell
# Run from an elevated PowerShell, or let the installer self-elevate:
.\install.ps1

# Silent install with all defaults:
.\install.ps1 -Silent

# Silent install, enable sudo in a new window:
.\install.ps1 -Silent -SudoMode forceNewWindow

# Skip sudo configuration:
.\install.ps1 -Silent -EnableSudo:$false
```

---

## Features

- **Biometric-first UAC** — Windows Hello PIN and fingerprint appear first, every time
- **Local account support** — works without a Microsoft Account
- **Windows sudo integration** — enables and configures Windows 11's built-in `sudo` command
- **State machine automation** — Task Scheduler precisely controls provider state across logon, logoff, lock, unlock, and startup
- **GPO coverage** — optional Group Policy shutdown/startup scripts for belt-and-suspenders coverage (Pro/Enterprise)
- **Full reversibility** — all original values are backed up and restored exactly on uninstall
- **Pre-flight safety check** — blocks install if no Windows Hello / PIN credential is detected
- **Helper command** — `hellosudo.cmd` for manual control and status inspection

---

## Safety Model

### Pre-flight Windows Hello Check

Before installing, hellosudo checks for the presence of NGC (Windows Hello PIN) credentials at:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\NgcPin\Credentials
```

If no credentials are found and `-IgnoreHelloCheck` is not specified:

- **Interactive mode**: A red warning is displayed and you must type `PROCEED` to continue.
- **Silent mode**: The installer throws a terminating error.

**Why this matters**: Suppressing the PasswordProvider without an active Windows Hello / PIN credential would leave ConsentUI with no available sign-in option, making all UAC elevations impossible.

### Metadata Backup

All original values are written to `HKLM:\SOFTWARE\hellosudo` before any changes are applied:

| Metadata key | Description |
|---|---|
| `TargetGUID` | The credential provider GUID being managed |
| `OriginalDisabledExisted` | Whether the `Disabled` value existed pre-install |
| `OriginalDisabledState` | The original value of `Disabled` |
| `OriginalConsentBehavior` | Pre-install `ConsentPromptBehaviorAdmin` |
| `OriginalSecureDesktop` | Pre-install `PromptOnSecureDesktop` |
| `InstalledTasks` | Which task triggers were registered |
| `InstalledGPScripts` | Which GPO script phases were configured |

### Logs

| Script | Log location |
|---|---|
| install.ps1 | `C:\ProgramData\hellosudo\logs\install.log` |
| uninstall.ps1 | `C:\ProgramData\hellosudo\logs\uninstall.log` |

---

## Windows sudo Integration

hellosudo enables Windows 11's built-in `sudo` command by default during installation.

```powershell
# Default: enable sudo in inline (normal) mode
.\install.ps1 -Silent

# Enable sudo in new-window mode
.\install.ps1 -Silent -SudoMode forceNewWindow

# Skip sudo configuration
.\install.ps1 -Silent -EnableSudo:$false
```

`SudoMode` values:

| Value | Registry | Behavior |
|---|---|---|
| `normal` | `3` | Inline elevation — inherits the current window |
| `forceNewWindow` | `1` | Always opens a new elevated window |
| `disableInput` | `2` | Elevated process runs without interactive input |

After install, `sudo` works natively:

```cmd
sudo powershell
sudo regedit
sudo "net localgroup Administrators"
```

Or use the helper:
```cmd
hellosudo sudo powershell
hellosudo sudo regedit
```

**Requirements**: Windows 11 24H2 or later. If `sudo.exe` is not present, hellosudo logs a warning and continues installation without configuring sudo.

---

## hellosudo.cmd Helper

`hellosudo.cmd` provides manual control and status inspection from any command prompt.

```cmd
hellosudo status              — Show full system state
hellosudo on                  — Manually enable biometric-first mode
hellosudo off                 — Manually restore standard mode
hellosudo sudo <command>      — Run via Windows sudo
```

Examples:

```cmd
hellosudo status
hellosudo sudo powershell
hellosudo sudo "reg query HKLM\SOFTWARE\hellosudo"
```

`hellosudo on` and `hellosudo off` request Administrator elevation automatically.

---

## Parameters

### install.ps1

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Silent` | switch | `$false` | Skip the interactive Review & Confirm menu |
| `-EnableSudo` | switch | `$true` | Enable Windows sudo during installation |
| `-SudoMode` | string | `normal` | Sudo mode: `normal`, `forceNewWindow`, `disableInput` |
| `-Tasks` | string[] | `Lock,Unlock,Logon,Logoff,Startup` | Task Scheduler trigger events |
| `-GPScripts` | string[] | `Shutdown` | GPO script phases (silently skipped on Home editions) |
| `-PasswordProviderGUID` | string | `{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}` | Credential provider GUID |
| `-IgnoreHelloCheck` | switch | `$false` | Bypass the Windows Hello pre-flight check |

All parameters support PowerShell tab-completion. `-Tasks` and `-GPScripts` accept any combination from their respective `ValidateSet` lists.

---

## Uninstall

```powershell
.\uninstall.ps1
```

The uninstaller:

1. Reads metadata from `HKLM:\SOFTWARE\hellosudo` (falls back to `HKLM:\SOFTWARE\uacbio` for legacy installs)
2. Removes both scheduled tasks from the `\hellosudo\` Task Scheduler folder
3. Removes hellosudo blocks from `scripts.ini` (handles both `# hellosudo` and `# uacbio` markers)
4. Runs `gpupdate /force` if GPO scripts were configured
5. Restores `ConsentPromptBehaviorAdmin` and `PromptOnSecureDesktop` to their pre-install values
6. Sets `PasswordProvider Disabled = 0` (re-enables the provider unconditionally)
7. Removes the `HKLM:\SOFTWARE\hellosudo` metadata key
8. Removes `C:\ProgramData\hellosudo` if empty

---

## Known Limitations

### "Run as different user" in File Explorer

When using **right-click → Run as different user** in Windows Explorer, the UAC prompt opens a CredUI window (not ConsentUI) that shows only the username/password fields. This flow does not respect the PasswordProvider state managed by hellosudo.

**CLI workaround**:
```cmd
runas /user:DOMAIN\adminuser "notepad.exe"
```

### Map Network Drive credentials

The network credential dialog (`net use` and the GUI map drive wizard) uses a separate credential flow unaffected by hellosudo.

**CLI workaround**:
```cmd
net use \\server\share /user:domain\user
```

### Legacy CredUI flows

Some older applications invoke `CredUIPromptForCredentials` directly, which bypasses ConsentUI entirely. hellosudo has no effect on these dialogs.

### Windows Hello must be configured first

hellosudo suppresses the PasswordProvider. If Windows Hello PIN or biometrics are not set up on the machine, this will leave ConsentUI with no available credential tile.

Set up Windows Hello before installing:
**Settings → Accounts → Sign-in options → Windows Hello PIN**

---

## Technical Reference

### State Matrix

| System Event | Task | PasswordProvider | Purpose |
|---|---|---|---|
| Logon | `hellosudo_Disable_Password` | `Disabled=1` | Biometric-first on login |
| Workstation Unlock | `hellosudo_Disable_Password` | `Disabled=1` | Biometric-first on unlock |
| Startup (boot) | `hellosudo_Restore_Password` | `Disabled=0` | Restore for boot flows |
| Workstation Lock | `hellosudo_Restore_Password` | `Disabled=0` | Restore on lock |
| Logoff (Event 7002) | `hellosudo_Restore_Password` | `Disabled=0` | Restore on session end |
| GPO Shutdown script | `scripts.ini [Shutdown]` | `Disabled=0` | Restore via Group Policy |
| GPO Startup script | `scripts.ini [Startup]` | `Disabled=0` | Restore via Group Policy |

### Registry Paths

| Path | Value | Purpose |
|---|---|---|
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}` | `Disabled` DWORD | Toggles PasswordProvider visibility in ConsentUI |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` | `ConsentPromptBehaviorAdmin` DWORD | Sets UAC prompt type for Administrators |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` | `PromptOnSecureDesktop` DWORD | Enforces Secure Desktop isolation |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo` | `Enabled` DWORD | Windows sudo mode (0=off, 1=new window, 2=input disabled, 3=normal) |
| `HKLM\SOFTWARE\hellosudo` | Various | Installation metadata and original value backups |

### GPO scripts.ini

When GPO script configuration is enabled, hellosudo appends to:
```
C:\Windows\System32\GroupPolicy\Machine\Scripts\scripts.ini
```

Entries are marked with `# hellosudo` and can be inspected or removed manually. The uninstaller removes all marked entries and can handle legacy `# uacbio` markers from prior installations.

