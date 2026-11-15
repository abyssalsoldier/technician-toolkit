# Endpoint Toolkit - Technician Manual

Welcome to the Endpoint Toolkit. This manual provides step-by-step instructions for technicians to efficiently set up, configure, and onboard Windows client workstations.

## 🚀 Getting Started

1. **Launch the Toolkit:** Double-click the `Launch.bat` file.
   * If you are running the local base repository, it will open instantly.
   * If you are running a locked `.exe`, it opens without a password. Modules marked **[LOCKED]** ask for the password the first time you click one (up to 3 attempts), and that unlocks all of them for the session.
   * If you are running from a USB portable toolkit, Windows asks for the drive's BitLocker password when you plug it in. The toolkit then checks for updates, copies itself locally so you can unplug the USB, and asks for the same password the first time you open a locked module.
2. **Navigation:** The toolkit interface consists of three main panels:
   * **Navigation Panel (Left):** Select modules to use (Dashboard, Software Manager, etc.), build a USB Toolkit, view the Session Report, or Quit.
   * **Action Panel (Center):** Displays the active module's interface (defaults to the Dashboard).
   * **Log Panel (Bottom):** Shows live execution logs. You can click and drag to resize this panel.

---

## 🛠️ Using the Modules

### 📊 Dashboard
The Dashboard provides an immediate, comprehensive overview of the endpoint's current state.
* **Review Health Badges:** Quickly scan the color-coded indicators for Windows Defender, Firewall, BitLocker, TPM, SentinelOne, and BitDefender.
    * 🟢 **Green:** Healthy / Active
    * 🔴 **Red:** Issue / Disabled
    * 🟡 **Yellow:** Warning (e.g. pending reboot)
    * ⚪ **Gray:** Unknown or Not Installed
* **Check Resources:** Monitor live CPU and RAM usage via the visual progress bars.
* **Refresh Data:** After running installations or fixes in other modules, click the **Refresh** button at the top to re-poll all system data.

### 📦 Software Manager
A unified software installer that pulls packages from Winget and local bundled installers.
1. **Load a Profile:** Click the **Client Profile** dropdown menu. Select a client's JSON profile to automatically check all software required for their standard build.
2. **Manual Selection:** Browse the categorized grids (Browsers, Productivity, etc.) and check/uncheck software manually as needed.
3. **Execute:** Click **Install Selected Software**. The toolkit will batch install everything sequentially, providing progress updates in the log panel. If Winget is missing on the machine, it will automatically install it first.

### 🧹 Debloat & Tweaks
Cleans up a fresh or OEM Windows install.
* **Pick items:** Tick items by category: bloatware apps (Xbox, Candy Crush, Clipchamp, etc.), McAfee trialware, telemetry and privacy (diagnostic data, advertising ID, Copilot, Recall), Start/taskbar/lock screen tweaks, USB selective suspend, Fast Startup/hibernation, and preinstalled Office products/languages. Use **Select All** or **Clear All** to speed this up.
* **Run:** Click **Run Selected**. Progress and results appear in the log panel. Office removal uses the bundled Office Deployment Tool.

### 🖥️ Computer Management
Simplifies renaming the workstation, joining it to a domain, and setting the clock.
* **Copy Serial Number:** Your current computer name and hardware serial number are displayed. Click the **Copy** button next to the serial number to quickly copy it to your clipboard for asset tracking.
* **Rename Computer:** Type a new name into the field and click **Rename**. (Requires a reboot to take effect).
* **Join Local Domain:** Enter the target Domain Name, along with your admin Username and Password, and click **Join Domain**. (Requires a reboot).
* **Join Azure AD (Entra ID):** Click the **Open Azure AD Join Screen** button. This instantly launches the native Windows "Access work or school" settings panel so you can complete the Entra join process.
* **Time & Date:**
    * **Time Zone:** Pick a zone and click **Apply**. A live preview shows the current time and the time after applying.
    * **Sync From:** Choose *Domain hierarchy* (domain-joined PCs), a preset NTP server, or type your own (separate multiple servers with spaces), then click **Apply**.
    * **Sync Time Now** forces an immediate resync. **Date and Time Settings** opens the Windows settings page.

### 🌐 Network Diagnostics
One-click troubleshooting for network connectivity issues.
* **Run Diagnostics:** Click the **Start Diagnostics** button. The toolkit will systematically test local connectivity, DNS resolution, Gateway ping, and DHCP status.
* **Review Results:** Each test provides a straightforward Pass/Fail indicator. If the "DNS Server Ping" fails but the "Public DNS Ping (1.1.1.1)" passes, you instantly know it's a local DNS issue and not an internet outage.

### 💽 Storage Management
Finds out what is filling a disk.
* **Scan:** Pick a drive (or **Browse Folder...**) and click **Scan**. NTFS drives are read directly from the MFT, so scans are fast. Click **Cancel** to stop a long scan.
* **Views:** **Browse** drills into folders with a treemap and breadcrumb. **Top Largest Files** and **Top Largest Folders** list the biggest offenders.

### 🔎 Crashfinder
Read-only health report for PCs that freeze or crash intermittently.
* **What it collects (last 30 days):** Unexpected shutdowns and bugcheck codes, minidumps and live kernel reports (WATCHDOG), WHEA/disk/driver errors, application hangs and crashes, Reliability Monitor, disk health, top processes, power plan and Fast Startup state, security/startup items, patch level, and graphics driver.
* **Output:** Saved as a text file in `C:\_INFO\Crashfinder`. Use **Open Report Folder** to view it.
* *Note: Changes nothing on the PC.*

### 🩺 System Repair
Repairs a damaged Windows install.
* **DISM + SFC:** Runs DISM `/RestoreHealth`, then `SFC /scannow`, with live progress, a live log view, and stall detection. You can cancel a run.
* **Repair source (optional):** Point DISM at an `install.wim`/`install.esd` that matches this Windows build, and set the index. Tick **Limit access** to stop it falling back to Windows Update.
* **Clear Temp Files:** Empties the current user's temp folder and `C:\Windows\Temp`. Files that are in use are skipped.

### 🚚 Migration Assist
Moves settings from an old Windows install to a new one (rebuilds, PC replacements).
* **Export (old install):** Tick the categories, choose a destination (USB drive or share), set a passphrase, and click **Export**. This creates a `Migration_<PCNAME>_<date>` folder. Sign in as the user who owns the printers and drives before exporting.
* **Import (new install):** Browse to the bundle folder, enter the passphrase, and click **Preview (no changes)** to see what would happen, then click **Import**. Existing items are skipped.
* **What moves:** printers with their drivers, mapped drives, Wi-Fi profiles, optional static IP, proxy, hosts file, VPN connections, software list, environment variables, default apps, third-party scheduled tasks, public certificates, time zone and region.
* **What does not move:** saved passwords (you are given a list to re-enter), certificate private keys, USB/WSD printers (add manually), and printer drivers that are not in the Windows driver store (reported by name). Printer drivers only transfer between the same architecture (x64 to x64).
* **Output:** A per-run report is saved in `C:\_INFO\MigrationAssist`. Use **Open Report Folder** to view it.

---

## 🔒 Advanced Distribution

### 📤 Exporting a Standalone Toolkit (For Remote Clients)
You can package your toolkit into a secure, password-protected executable (`.exe`) to email or send to external sites.
1. Open a PowerShell console as Administrator.
2. Run the export script: `.\dependencies\Agent\Export-LockedToolkit.ps1`
3. Enter a custom password of at least 8 characters when prompted (the recipient will need this password).
4. Provide an output path (e.g., `C:\Users\Public\Desktop`).
5. The script will bundle the entire toolkit and compile it into `EndpointToolkit_Locked.exe`.

Client builds are easier from the **Client Setup** wizard (`Setup-Client.bat` → **Check & Build**), which also offers **Build exe + folder** for a plain, ready-to-run copy.

### 💾 Building a USB Portable Toolkit (For Offline Sites)
The USB Toolkit allows you to build a secure, portable version for client sites. The drive is protected with BitLocker To Go.
1. Insert a USB flash drive (16 GB or larger).
2. Click the **USB Toolkit** button in the left navigation panel.
3. Click **Prepare Drive** to automatically format the drive to NTFS and label it "TOOLKIT".
4. Enter your custom password (8+ characters, a BitLocker requirement) into the **USB Toolkit Password (Required)** field. Anyone using the USB will need it.
5. Click **Setup USB**. The module copies the toolkit and all local installers onto the drive, then encrypts it with BitLocker. Wait for **USB setup complete!** before unplugging. (Building requires Windows Pro/Enterprise.)

**Using the USB Toolkit:**
1. Plug the USB drive into a client computer and enter the BitLocker password when Windows prompts you (this works on Windows Home too).
2. Run `Launch.bat` from the drive.
3. If a newer version has been released, you'll be asked whether to update the USB first. The download is checksum-verified before anything is replaced.
4. The toolkit copies itself to a temporary local folder. **Once the toolkit window appears, you can safely unplug the USB drive and move to the next computer!**
5. When you open a **[LOCKED]** module, enter your custom USB password to unlock the locked modules.

### 🔄 Updating the Toolkit
* USB toolkits update themselves from the GitHub releases of `abyssalsoldier/technician-toolkit` whenever they're launched with internet access. You're only prompted when a **newer** version exists.
* A USB with locked modules doesn't self-update. Re-create it with **USB Toolkit** from the new version.
* **To publish a new version:** bump `dependencies/version.txt`, commit, and push to `master`. The GitHub Action builds and publishes the release automatically.

---

## 🧹 Proper Cleanup
* **Close the toolkit when you're done:** click **Quit** in the bottom-left corner of the navigation panel (closing the window with X does the same).
* Closing clears the password-protected data from memory and deletes the toolkit's temporary copy and working files from the endpoint. Reports saved to `C:\_INFO\` stay on purpose.