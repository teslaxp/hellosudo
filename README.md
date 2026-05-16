# uacbio

> **Windows UAC Biometric Fix for Local Accounts**  
> Dynamically toggles the `PasswordProvider` credential provider so that ConsentUI surfaces biometrics immediately — no "More choices" click required.

---

## Table of Contents

1. [Description](#description)
2. [The Problem](#the-problem)
3. [The Solution — State Matrix](#the-solution--state-matrix)
4. [Installation](#installation)
5. [Uninstallation](#uninstallation)
6. [Logging](#logging)
7. [Known Limitations](#known-limitations)

---

## Description

**uacbio** is a lightweight Windows automation project that fixes a chronic usability issue with UAC (User Account Control) prompts on Windows 11 machines using **local accounts**.

It works in two complementary layers:

1. **UAC Policy (core, mandatory):** On installation, uacbio sets `ConsentPromptBehaviorAdmin = 1` and `PromptOnSecureDesktop = 1` in the Windows policy registry. This forces the Administrator UAC prompt to request an explicit credential — password *or* biometric — on the isolated Secure Desktop, rather than silently auto-elevating or showing a plain consent dialog. Original values are preserved in metadata and fully restored on uninstall.

2. **PasswordProvider toggling:** uacbio dynamically writes a single `Disabled` DWORD under the `PasswordProvider` credential provider GUID at precisely the right moments using Windows Task Scheduler triggers and optional Group Policy scripts. When the provider is disabled, ConsentUI falls through to the next available provider — Windows Hello biometrics — so fingerprint or face recognition appears immediately at the UAC prompt.

Both layers operate exclusively through native Windows registry keys and built-in scheduling mechanisms. No third-party software, no drivers, no kernel patches — and **no dependency on Group Policy infrastructure**, making the solution work flawlessly on both Windows Home and Pro editions.

---

## The Problem

### Microsoft Accounts vs. Local Accounts in ConsentUI

When a UAC elevation prompt appears (`ConsentUI.exe`), Windows enumerates all registered credential providers to build the list of sign-in options. The behavior differs critically between account types:

| Account Type      | Biometrics at UAC prompt |
|-------------------|--------------------------|
| Microsoft Account | ✅ Shown immediately     |
| Local Account     | ❌ Hidden behind **"More choices"** |

The root cause is the **PasswordProvider** credential provider (`{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}`). When it is active (i.e. its `Disabled` DWORD is `0` or absent), ConsentUI selects it as the *default* provider for local accounts and renders a password field first — pushing Windows Hello / biometrics to a secondary "More choices" menu.

**Disabling** this provider (setting `Disabled = 1`) causes ConsentUI to fall through to the next available credential provider — which, if Windows Hello is configured, is the biometric provider. This makes fingerprint / face recognition appear immediately on the UAC prompt.

The challenge is that this registry value must be managed dynamically: disabled during an active session (so UAC uses biometrics) and restored at session boundaries (to keep the standard login flow intact for next sign-in).

---

## The Solution — State Matrix

uacbio operates in two complementary layers that together guarantee biometrics appear immediately at every UAC prompt.

### Layer 1 — UAC Policy (applied once at install, works on Home & Pro)

| Registry Value | Key | Set To | Effect |
|---|---|---|---|
| `ConsentPromptBehaviorAdmin` | `...\Policies\System` | `1` | Forces credential/biometric prompt for Admins (instead of silent consent) |
| `PromptOnSecureDesktop` | `...\Policies\System` | `1` | Ensures the prompt runs on the isolated Secure Desktop |

These two values are the prerequisite that makes biometrics available at the UAC prompt. They target native system registry keys directly, bypassing Group Policy infrastructure entirely, so they work identically on **Windows Home** and **Windows Pro**.

### Layer 2 — PasswordProvider Dynamic Toggling (via Task Scheduler + optional GPO)

uacbio registers Scheduled Tasks and optional Group Policy scripts to toggle the `Disabled` value at each system state transition:

| System Event          | Action                    | Mechanism             |
|-----------------------|---------------------------|-----------------------|
| **Install**           | Set `ConsentPromptBehaviorAdmin=1`, `PromptOnSecureDesktop=1` | Registry (core) |
| **Logon**             | Set `Disabled = 1`        | Task Scheduler        |
| **Workstation Unlock**| Set `Disabled = 1`        | Task Scheduler        |
| **Workstation Lock**  | Set `Disabled = 0`        | Task Scheduler        |
| **Logoff** (Event 7002)| Set `Disabled = 0`       | Task Scheduler        |
| **Startup**           | Set `Disabled = 0`        | Task Scheduler        |
| **Shutdown** (GPO)    | Set `Disabled = 0`        | Group Policy Script   |
| **Startup** (GPO)     | Set `Disabled = 0`        | Group Policy Script   |
| **Uninstall**         | Restore `ConsentPromptBehaviorAdmin` + `PromptOnSecureDesktop` to originals | Registry |

> Both scheduled tasks run under the **SYSTEM** account with **HighestAvailable** privileges, ensuring they execute regardless of which user is active.

The two registered tasks are:

| Task Name                    | Sets `Disabled` | Default Triggers          |
|------------------------------|-----------------|---------------------------|
| `uacbio_Disable_Password`    | `1` (disable)   | Logon, Workstation Unlock |
| `uacbio_Restore_Password`    | `0` (restore)   | Startup, Lock, Logoff     |

---

## Installation

### Prerequisites

- Windows 11 (or Windows 10 with Windows Hello configured)
- PowerShell 5.1 or later (or PowerShell 7+)
- Administrator privileges (the script auto-elevates if needed)

### Quick Start

```powershell
# Interactive install — presents a Review & Confirm menu
.\install.ps1

# Silent install with all defaults
.\install.ps1 -Silent

# Custom: only register Logon + Unlock triggers, add GPO Shutdown script, silent
.\install.ps1 -Silent -Tasks Logon,Unlock -GPScripts Shutdown
```

### Parameters

All parameters support **tab-completion** in PowerShell (via `ValidateSet`) — press <kbd>Tab</kbd> after the parameter name to cycle through valid values.

---

#### `-Tasks`

**Type:** `string[]`  
**Default:** `@('Lock', 'Unlock', 'Logon', 'Logoff', 'Startup')`  
**Valid values:** `Lock`, `Unlock`, `Logon`, `Logoff`, `Startup`

Selects which system state transitions to register as Scheduled Task triggers.

```powershell
# Minimal: only fix UAC during active session (Logon + Unlock triggers)
.\install.ps1 -Tasks Logon,Unlock -Silent

# Tab-completion example (type and press Tab):
.\install.ps1 -Tasks Lo<Tab>   # cycles: Lock → Logon → Logoff
```

> **Autocomplete note:** Because `-Tasks` is declared with `[ValidateSet(...)]`, PowerShell's tab-completion engine automatically offers `Lock`, `Unlock`, `Logon`, `Logoff`, and `Startup` as completions — no extra configuration required.

---

#### `-GPScripts`

**Type:** `string[]`  
**Default:** `@('Shutdown')`  
**Valid values:** `Startup`, `Shutdown`

Configures Group Policy Machine Scripts (`shutdown.ini` / `startup.ini`) as an additional safety net to ensure `Disabled` is reset even if the Task Scheduler is bypassed (e.g., forced power-off).

```powershell
# Add both Shutdown and Startup GP scripts
.\install.ps1 -GPScripts Startup,Shutdown -Silent

# Disable GPO scripts entirely
.\install.ps1 -GPScripts @() -Silent
```

> **Windows Home note:** Local Group Policy is not available on Windows Home editions. If a Home edition is detected, GPO script configuration is **silently skipped** — no error is raised and all Task Scheduler features still work normally.

---

#### `-PasswordProviderGUID`

**Type:** `string`  
**Default:** `{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}`

The registry GUID of the `PasswordProvider` credential provider. Must include surrounding braces. You should not need to change this unless Microsoft ships a different provider GUID in a future Windows update.

```powershell
.\install.ps1 -PasswordProviderGUID '{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}'
```

---

#### `-Silent`

**Type:** `switch`  
**Default:** not set (interactive mode)

Suppresses the interactive Review & Confirm menu and proceeds immediately with the current parameter values. Useful for scripted deployments.

```powershell
.\install.ps1 -Silent
```

---

### Interactive Mode

When `-Silent` is **not** specified, the installer presents a Review & Confirm menu:

```
╔══════════════════════════════════════════════════════════╗
║          uacbio  ·  Review & Confirm Installation        ║
╠══════════════════════════════════════════════════════════╣
║  Provider GUID : {60b78e88-ead8-445c-9cfd-0b87f74ea6cd} ║
║  Tasks         : Lock, Unlock, Logon, Logoff, Startup    ║
║  GPO Scripts   : Shutdown                                 ║
╠══════════════════════════════════════════════════════════╣
║  [C] Continue with these settings                         ║
║  [T] Change Tasks selection                               ║
║  [G] Change GPO Scripts selection                         ║
║  [Q] Quit                                                 ║
╚══════════════════════════════════════════════════════════╝
```

The displayed values always reflect the *current* parameter values — whether those are the script defaults or values you passed on the command line. You can adjust Tasks and GPO Scripts interactively before confirming.

---

### What Gets Installed

| Component | Location |
|---|---|
| UAC policy (core) | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` |
| Scheduled Task (disable) | `\uacbio_Disable_Password` in Task Scheduler |
| Scheduled Task (restore) | `\uacbio_Restore_Password` in Task Scheduler |
| GPO Shutdown script | `C:\Windows\System32\GroupPolicy\Machine\Scripts\Scripts\shutdown.ini` |
| GPO Startup script | `C:\Windows\System32\GroupPolicy\Machine\Scripts\Scripts\startup.ini` |
| Metadata registry key | `HKLM\SOFTWARE\uacbio` |
| Log file | `C:\ProgramData\uacbio\logs\install.log` |

---

## Uninstallation

```powershell
.\uninstall.ps1
```

The uninstaller:

1. Reads metadata from `HKLM\SOFTWARE\uacbio`
2. Removes both scheduled tasks (`uacbio_Disable_Password`, `uacbio_Restore_Password`)
3. Removes uacbio blocks from `shutdown.ini` and `startup.ini` (if present), then runs `gpupdate /force`
4. **Reverts `ConsentPromptBehaviorAdmin` and `PromptOnSecureDesktop`** to their original pre-install values (stored in metadata)
5. Reverts the `PasswordProvider` `Disabled` value to its **original state** (as captured during install)
6. Deletes the `HKLM\SOFTWARE\uacbio` metadata key
7. Removes `C:\ProgramData\uacbio` if it is empty

> If the metadata key is missing (e.g., uacbio was never installed), the uninstaller logs an error and exits without making any changes.

---

## Logging

Both scripts write detailed timestamped logs:

| Script | Log file |
|---|---|
| `install.ps1` | `C:\ProgramData\uacbio\logs\install.log` |
| `uninstall.ps1` | `C:\ProgramData\uacbio\logs\uninstall.log` |

Log entries include the timestamp, severity level (`INFO`, `WARN`, `ERROR`), and a descriptive message for every registry read/write, task registration, GPO modification, and elevation attempt.

Example log lines:
```
[2025-06-01 14:32:10] [INFO] OS detected   : Windows 11 Pro
[2025-06-01 14:32:10] [INFO] Current 'Disabled' value: 0
[2025-06-01 14:32:11] [INFO] Registered task: uacbio_Disable_Password
[2025-06-01 14:32:11] [INFO] Updated GPO ini '...shutdown.ini' — added [Shutdown] block at index 0.
```

---

## Known Limitations

### "Run as different user" GUI Block

The UAC "Run as different user" dialog (`ConsentUI` in `runasdifferentuser` mode) is **not affected** by this fix. When you right-click → *Run as different user*, Windows always presents a full credential prompt that is not filtered by the `PasswordProvider` `Disabled` flag — the dialog hard-codes the password credential UI regardless of provider state.

**Workaround using `runas /user:` from the command line:**

The `runas` command-line utility respects the credential provider state. You can use it as a functional equivalent:

```cmd
runas /user:DOMAIN\AdminUser "notepad.exe"
```

Or with the local machine name:

```cmd
runas /user:COMPUTERNAME\Administrator "C:\path\to\app.exe"
```

After running this command, Windows will prompt for a password in the terminal. This flow **does** benefit from uacbio: if you have Windows Hello PIN set up for the target account, some elevation flows will offer it.

> **Tip:** You can combine `runas` with `cmd /c start ""` to launch GUI applications in a new window under a different identity while keeping your current terminal session intact.

### Scope

- uacbio targets the **currently logged-in local account** session. It has no effect on domain-joined machines where interactive UAC prompts are handled by domain credential providers.
- Windows Hello / biometrics must already be configured on the machine for the fix to have a visible effect.
- The `PasswordProvider` GUID (`{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}`) is correct for all currently known Windows 11 builds. If Microsoft changes this GUID in a future update, pass the new GUID via the `-PasswordProviderGUID` parameter.

---

## License

MIT
