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

hellosudo configures two core components:

### 1. UAC Credential Policy (Mandatory)

Configures the Administrator prompt to require explicit credentials (biometrics/PIN) rather than a simple "Yes" click on the Secure Desktop.

| Registry Value | Set to | Effect |
| --- | --- | --- |
| `ConsentPromptBehaviorAdmin` | `1` | Enables biometric flow in ConsentUI |
| `PromptOnSecureDesktop` | `1` | Enforces the isolated Secure Desktop environment |

### 2. PasswordProvider State Machine (Dynamic)

The PasswordProvider (`{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}`) is the tile that displays the password field. hellosudo installs **Task Scheduler** jobs to toggle its `Disabled` state:

* **Logon / Unlock:** Sets `Disabled = 1` (Surfaces biometrics first).
* **Lock / Logoff / Startup:** Sets `Disabled = 0` (Restores standard flow for safety).

---

## Quick Install

Run from an elevated PowerShell (Admin):

```powershell
# Interactive install with Review & Confirm menu:
.\install.ps1

# Silent install (all defaults):
.\install.ps1 -Quiet

# Silent install, skip sudo configuration:
.\install.ps1 -Quiet -SkipSudo

# Bypass the Windows Hello safety check (Advanced):
.\install.ps1 -Quiet -SkipHelloCheck

```

---

## Features

* **Biometric-First UAC:** Windows Hello PIN and fingerprint appear first, every time.
* **Windows Sudo Integration:** Automatically enables and configures the 24H2 `sudo` command.
* **Smart State Machine:** Precise control via Task Scheduler (Logon, Lock, Unlock, etc.).
* **GPO Coverage:** Optional Startup/Shutdown script support for Pro/Enterprise editions.
* **Safety First:** Pre-flight check prevents system lockout if no PIN/biometric is configured.
* **Full Reversibility:** Metadata backup allows `uninstall.ps1` to restore 100% of original settings.

---

## Parameters (`install.ps1`)

| Parameter | Alias | Default | Description |
| --- | --- | --- | --- |
| `-Quiet` | `-Silent`, `-q` | `$false` | Skips the interactive Review & Confirm menu. Ideal for automation. |
| `-SkipSudo` | `-NoSudo`, `-nosd` | `$false` | Prevents the script from enabling and configuring Windows `sudo`. |
| `-SkipHelloCheck` | `-NoHelloCheck`, `-nohc` | `$false` | Bypasses the Windows Hello pre-flight safety check. **WARNING: Extremely dangerous.** If no working PIN or biometric is available and this flag is used, you may be unable to log into Windows at all. |
| `-SudoMode` | `-sm` | `normal` | Defines the native Windows sudo execution layout: `normal`, `forceNewWindow`, `disableInput`. |
| `-Triggers` | `-Tasks`, `-tgs` | (All) | System events that cycle the tile visibility: `Lock, Unlock, Logon, Logoff, Startup`. |
| `-GpoScripts` | `-GPScripts`, `-Scripts`, `-gps` | `Shutdown` | Local Group Policy script phases to hook into. (Ignored on Windows Home). |
| `-PasswordProviderGuid` | `-pwdid`, `-pwdguid` | `{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}` | The system GUID of the target Credential Provider tile to manipulate. |

---

## Safety & Metadata

### Pre-flight Check

If no Windows Hello PIN/Biometric is detected, the installer will **abort** in silent mode or require a `PROCEED` confirmation in interactive mode. This prevents you from disabling the password provider and being locked out of Windows entirely.

> [!CAUTION]
> **The PasswordProvider controls authentication at the Windows login screen, not only UAC.** If hellosudo's Task Scheduler jobs fail to restore `Disabled = 0` before a login is required — for example, after an unexpected power loss, a Windows Update that disables scheduled tasks, or a scheduler failure — **you will be unable to log into Windows** even with a correct password, unless Windows Hello is working flawlessly at that moment. Ensure you have a recovery strategy before installing (e.g., a Windows Recovery Environment (RE) USB drive or a second local administrator account).

### Metadata Backup

Original values are stored in `HKLM:\SOFTWARE\hellosudo` before any changes. This ensures that `uninstall.ps1` can return your system to its exact previous state.

### Logs

* **Install:** `C:\ProgramData\hellosudo\logs\install.log`
* **Uninstall:** `C:\ProgramData\hellosudo\logs\uninstall.log`

---

## Known Limitations

> [!CAUTION]
> **Risk of total system lockout.** hellosudo suppresses the PasswordProvider system-wide. This provider controls authentication at **all** Windows credential prompts — including the login screen and lock screen, not just UAC. If the Task Scheduler jobs fail to restore `Disabled = 0` before a login is required (power loss, Windows Update interference, scheduler failure), **you will be locked out of Windows entirely** — not just unable to elevate privileges. Always ensure Windows Hello (PIN or biometric) is working correctly, and keep a recovery option available (bootable USB, Windows RE, or a second admin account).

> [!IMPORTANT]
> The following specific Windows flows are intentionally affected while hellosudo is active:

1. **"Run as different user":** Right-clicking and selecting this will show no password field. Use `runas /user:Account "app.exe"` instead.
2. **Network Map Drive:** Entering alternative credentials via GUI might fail. Use `net use` via CLI.
3. **Multi-user machines:** The setting is machine-wide. All users will see the biometric-first prompt.
4. **Task Scheduler dependency:** The safe cycling of the PasswordProvider state depends entirely on scheduled tasks running reliably. Disabling, deleting, or corrupting these tasks without running `uninstall.ps1` first may leave the system in an unsafe state.

---

## Uninstall

To completely revert all changes, remove tasks, and restore registry values:

```powershell
.\uninstall.ps1

```
