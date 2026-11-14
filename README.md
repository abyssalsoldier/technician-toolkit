# Endpoint Toolkit Architecture

A powerful, PowerShell-based endpoint onboarding and automation toolkit designed for managed service providers (MSPs). This document outlines the technical architecture, security mechanisms, and extensibility of the toolkit. For step-by-step instructions on *using* the toolkit, please see the [User Guide](UserGuide.md).

## 🏗️ Core Architecture & UI

### WPF & PowerShell Runspaces
The toolkit interface is built using Windows Presentation Foundation (WPF) rendered entirely via PowerShell. To prevent the UI thread from freezing during long-running tasks (like software installations or WMI queries), the toolkit employs an advanced asynchronous **Runspace Architecture**:
*   **Synchronized State:** A global thread-safe synchronized hash table (`$Global:SyncHash`) is used to pass data seamlessly between the background runspaces and the primary UI thread.
*   **Non-Blocking Execution:** Heavy tasks (e.g., retrieving system metrics, polling Winget, joining domains) are dispatched to independent runspaces. When complete, a dispatcher invokes updates directly back to the WPF UI controls, keeping the dashboard highly responsive.

### Extensible Module System
The toolkit is built on a dynamic, plug-and-play architecture:
*   **Auto-Discovery:** Modules are automatically discovered and registered by dropping a `.ps1` file into the `dependencies/Modules/` directory.
*   **Registration:** Modules must expose a `Register-<Name>` function returning a hash table with `Name`, `Label`, `RequiresAuth`, `EntryPoint`, and `UIDefinition`. The core orchestrator dynamically builds the navigation menu based on these functions.

## 🔒 Zero-Trust Security & Distribution

The toolkit handles sensitive environment access, so the entire repository and execution lifecycle is built under a strict zero-trust philosophy.

### Unlocked Base Repository
The raw repository code (in `dependencies/`) contains no hardcoded credentials, API keys, or client data. When run locally via `Launch.bat`, the base toolkit launches completely unlocked. This ensures a frictionless experience for developers and kit builders.

### Password-Protected SFX Export
For external deployment, the toolkit can be securely compiled using `Export-LockedToolkit.ps1`. 
*   **Compilation:** The script copies the raw toolkit into a temporary folder, prompts the admin for a distribution password, and generates an AES-256 encrypted `.sfx-key`. 
*   **Stub Injection:** It compiles a standalone C# Self-Extracting Executable (SFX) on the fly and binds the zip payload to it.
*   **Execution:** When run on a client machine, the SFX demands the correct password to decrypt the `.sfx-key` before allowing access.

### BitLocker-Protected USB Portable Mode
For off-grid environments, the `Setup-UsbToolkit` module turns a standard USB flash drive (16 GB+) into a portable toolkit.
*   **Plain files, encrypted drive:** The toolkit is copied onto the stick as normal files (no executable is built), and the drive is protected with **BitLocker To Go** (XTS-AES 256) using the technician's custom password. The drive stays fully rewritable. BitLocker requires a password of at least 8 characters. If enabling BitLocker fails, the toolkit files are removed from the drive.
*   **Requirements:** Only *enabling* BitLocker needs Windows Pro/Enterprise on the build machine. Any Windows edition, including Home, can unlock the drive with the password.
*   **Hardware-bound toolkit key:** A hidden `.toolkit-key` stores the toolkit key encrypted with the drive's **hardware serial number** plus the custom password. After the drive is unlocked, the toolkit asks for that same password to unlock its features. A `.toolkit-key` copied to another stick won't decrypt.

### Run-From-Local-Copy
When `Launch.bat` is started from a USB drive, the toolkit first checks for updates (see below), then copies itself to a randomized `%TEMP%\EndpointToolkit_<guid>` folder with a progress window and re-points the running instance at that copy. Once the main window appears, the technician can **pull the USB** and move to the next PC. The local copy is deleted on exit. If the copy fails, the toolkit warns that it is running from the USB and must not be unplugged.

### Self-Update from GitHub Releases
USB toolkits update themselves from this repository's [GitHub Releases](https://github.com/abyssalsoldier/Endpoint-toolkit/releases).
*   **Publishing:** `.github/workflows/release.yml` runs on every push to `master`. If no release exists yet for the version in `dependencies/version.txt`, it builds a clean `latest.zip`, computes `latest.sha256`, and publishes release `vX.Y.Z` with `latest.zip`, `latest.sha256`, and `version.txt` attached. Pushes that don't bump the version publish nothing.
*   **Checking:** On launch from a USB, the toolkit reads `releases/latest/download/version.txt`. Only a *newer* version triggers an update prompt (a message box, since the console is hidden).
*   **Integrity:** The downloaded zip must match `latest.sha256` or the update is aborted. A missing or malformed checksum also aborts.
*   **Deploying:** The release is mirrored onto the USB (files removed from the release are removed from the stick). Technician-added files in `CustomInstallers/` are kept, and the toolkit relaunches at the new version.
*   **To ship a release:** bump `dependencies/version.txt`, commit, and push to `master`.

### Volatile Execution & Cleanup
Whether executing from a distributed SFX `.exe` or a USB drive, the toolkit strictly enforces ephemeral execution:
1.  **Extraction:** The SFX extracts to the Windows `%TEMP%` directory, and USB launches run from a randomized local copy in `%TEMP%`.
2.  **Detached Execution:** Once the toolkit is running from `%TEMP%`, the `.exe` or USB is no longer needed.
3.  **Wipe:** Upon clicking the **Quit** button in the UI, a cleanup routine explicitly wipes all temporary folders, the local copy, downloaded installers, decrypted keys, and active PowerShell sessions from memory and disk.

## 🧩 Modules
| Module | What it does |
|---|---|
| **Software Manager** | Hybrid winget + `CustomInstallers/` package manager. See [SOFTWARE_CATALOG.md](SOFTWARE_CATALOG.md). |
| **Debloat & Tweaks** | Removes bloatware apps and McAfee trialware, disables telemetry/Copilot/Recall, tunes Start/taskbar/lock screen, fixes USB power management, and removes preinstalled Office languages/products via the bundled Office Deployment Tool (`CustomInstallers/ODT/setup.exe`). |
| **Computer Management** | Rename, AD / Entra ID join, serial copy, and **Time & Date**: time zone picker with live preview, time source (domain hierarchy, `time.windows.com`, `pool.ntp.org`, `time.nist.gov`, `time.google.com`, or a custom NTP list), and Sync Now. |
| **Network Diagnostics** | One-click connectivity, DNS, gateway and DHCP tests. |
| **Storage Management** | WizTree-style disk usage scan with a treemap. NTFS volumes are read directly from the MFT, other file systems use a directory walk. Browse, Top Largest Files, and Top Largest Folders views. |
| **Crashfinder** | Read-only freeze/crash report covering the last 30 days (bugchecks, live kernel reports, WHEA/disk/driver errors, app hangs, disk health, power/Fast Startup). Saved to `C:\_INFO\Crashfinder`. |
| **System Repair** | DISM + SFC with live progress parsed from the tools' own output, stall detection, an optional WIM/ESD repair source, and Clear Temp Files. |
| **Migration Assist** | Exports and imports printers (with drivers), mapped drives, Wi-Fi, static IP/proxy/hosts/VPN, and system settings between Windows installs. Secrets are encrypted with a passphrase, Preview mode makes no changes, and reports are saved to `C:\_INFO\MigrationAssist`. |

## 📂 File Structure

```text
endpoint-build-toolkit/
├── Launch.bat                          Entry point (elevates, prioritizes PowerShell 7)
├── dependencies/
│   ├── Invoke-EndpointSetup.ps1        WPF orchestrator & cleanup routine
│   ├── Core/                           Infrastructure (Crypto, Auth, USB Detection)
│   ├── UI/                             XAML layouts and Runspace synchronization
│   ├── Modules/                        Feature Modules (see the Modules table above)
│   ├── Profiles/                       JSON templates for client software builds
│   ├── Agent/                          Admin tools (e.g., Export-LockedToolkit.ps1)
│   ├── CustomInstallers/               Bundled static offline installers (ODT/ is used by Debloat)
│   └── version.txt                     Toolkit version (bump to publish a release)
├── SOFTWARE_CATALOG.md                 winget packages offered by Software Manager
├── build.ps1                           Local build / test script (_builds/)
└── .github/workflows/release.yml       Publishes GitHub Releases used by self-update
```

## ⚙️ Administration & Requirements

### Automated Software Provisioning
The `Install-Software` module acts as a hybrid package manager. It dynamically queries Microsoft's `winget` repository alongside the `CustomInstallers/` directory. If `winget` is missing from the target endpoint, the toolkit will automatically bootstrap and install it before proceeding.

### Requirements
*   **OS:** Windows 10 / 11
*   **PowerShell:** v5.1 minimum (v7+ natively preferred by Launch.bat)
*   **Privileges:** Local Administrator (toolkit will prompt to self-elevate)
*   **Connectivity:** Internet required for winget and self-update (the toolkit runs offline from USB otherwise).
*   **USB builds:** Windows Pro/Enterprise/Education on the machine that builds the USB (for BitLocker To Go).