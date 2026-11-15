# Client Guide: Your Own Branded Toolkit

This guide is for IT teams who run the Endpoint Toolkit under their own name, with their own colors, modules and installers. **You don't need GitHub or Git.** Everything is done with a setup wizard. GitHub is optional, for teams that want version control and their own update feed. If you use an AI coding agent, point it at [AGENTS.md](AGENTS.md).

---

## How it works

Your toolkit has two parts:

| Part | Where | Who changes it |
|---|---|---|
| **Core** | Everything **except** `client\` (`dependencies\`, `Launch.bat`, `build.ps1`, `tools\`, ...) | Only the toolkit provider. You receive new core versions as updates. |
| **Your client folder** | `client\` | You, through the wizard. Your branding, modules, installers and version number. |

The toolkit reads `client\` at launch. This works the same way for `Launch.bat`, a USB stick, the exe, the password-locked exe, and ConnectWise Control Toolbox runs. Because your changes live only in `client\`, a new core version never overwrites them.

**Core files are protected.** Every core file is listed with a checksum in `dependencies\core-manifest.json`. The wizard, `build.ps1` and the locked-exe export check them and **refuse to build if a core file was changed**. If that happens, re-extract the client kit, keeping your `client\` folder.

---

## Quick start (no GitHub)

1. Download **`client-kit.zip`** from the toolkit provider's latest release and extract it to a folder you keep, for example `C:\Toolkit`.
2. Double-click **`Setup-Client.bat`**. No admin rights are needed.
3. Work through the wizard:
   1. **Welcome:** shows the core version and confirms the core files are original.
   2. **Brand:** product name, accent color (with a live preview of the title bar), logo, support contact, your version.
   3. **Modules:** hide modules, lock modules behind the password, add or remove your own modules.
   4. **Secrets:** values your modules need that must stay protected, such as RMM site keys and tokens (see [Secrets and locked kits](#secrets-and-locked-kits)).
   5. **Installers:** add your `.exe`/`.msi` installers, for example your RMM agent.
   6. **Updates:** choose how USB toolkits update (see [Updates](#updates)).
   7. **Check & Build:** run the checks, then **Build exe + folder**, **Build locked exe** or **Make USB**.
4. Your builds are in `C:\Toolkit\_builds\`, or in the **Output folder** you chose on the Check & Build page (any folder outside the toolkit folder; the wizard remembers it on this PC). The exe names stay `EndpointToolkit.exe` and `EndpointToolkit_Locked.exe`, so existing ConnectWise Toolbox entries keep working.

Run `Setup-Client.bat` again at any time to make changes. It loads your current settings.

---

## Modules

The **Modules** page lists every core module and every module of yours:

| Column | Meaning |
|---|---|
| **Show** | Untick to hide the module from the menu (`DisabledModules`). |
| **Lock** | Tick to require the toolkit password for it (`LockedModules`). Applies to the locked exe and USB builds; running from the folder is always unlocked. **Lock all** locks every module, including ones added later. A module that always requires the password shows a ticked box you can't change. |
| **Source** | `Core`, `Client`, or `Replaces core` (your module replaces the core module with the same name). |

- **Add module file:** pick a `.ps1`. The wizard **checks it before copying it in**, by reading it without running it. It is rejected if:
  - it has syntax errors
  - its registration is missing or incomplete
  - its entry function is missing
  - it reuses a name another module already uses
  - it redefines a core function (except when it intentionally replaces that core module)
  - it writes into core folders

  It warns about code that runs at load time, `Read-Host`, and dependence on the user profile (these break under ConnectWise / SYSTEM).
- **Create new module from template:** type a name, for example `Acme RMM`. The wizard creates `client\Modules\AcmeRMM.ps1` from the template and offers to open it.
- **Remove:** moves your module file into `client\_removed\` (never shipped), so you can restore it later. Core modules can be hidden, not removed.
- **Export guide for AI agent...:** saves a self-contained `.md` file (for example `Acme-IT-Toolkit-MODULE-GUIDE.md`) to give to an AI coding agent. It contains:
  - the module contract, API and rules
  - the exact checks the wizard runs
  - a template
  - your product name, core version and installed modules
  - the core function names to avoid

  Save it outside the toolkit folder, have the agent write the module, then add it with **Add module file...**.

### Writing a module

A module is one `.ps1` file in `client\Modules\` with a `Register-<Something>` function:

```powershell
function Register-AcmeRmm {
    @{
        Name           = 'Acme-RMM'          # unique ID. Reusing a core Name REPLACES that core module.
        Label          = 'RMM Agent'         # menu text
        Description    = 'Install and check the Acme RMM agent'
        RequiresAuth   = $false              # $true = always locked (the wizard's Lock box does this per build)
        SortOrder      = 60                  # menu position (core modules use 20-50)
        EntryPoint     = 'Start-AcmeRmm'     # runs in a background runspace
        UIDefinition   = 'Get-AcmeRmmUI'     # optional: your own panel. Without it you get a "Run" button.
        MinCoreVersion = '2.1.0'             # optional: skipped (with a log warning) on older cores
        Secrets        = @('AcmeRmmSiteKey') # every secret it reads with Get-ToolkitSecret (omit or @() for none)
    }
}
```

**The module API.** These are everything a module needs. Nothing requires changing core:

| Use | For |
|---|---|
| `Start-ModuleInBackground -Module (Register-AcmeRmm)` | Run your EntryPoint in the background, recorded in the Session Report |
| `Write-Log 'text' -Level Info\|Success\|Warning\|Error` | The log panel (works in background tasks) |
| `New-ToolkitBrush`, `New-ToolkitBrush '#A6ADC8'`, `Get-ToolkitAccent` | Your brand color in your UI |
| `Get-ToolkitClientRoot` | Path of `client\` at runtime, for example `Join-Path (Get-ToolkitClientRoot) 'CustomInstallers\agent.msi'` |
| `Get-ToolkitClientDataPath ['name']` | A working folder for files your module writes **during a session** (wiped on Quit for USB/exe runs) |
| `C:\_INFO\<YourModule>\` | Reports and anything that must survive (same as the core modules) |
| `Get-ToolkitProductName`, `Get-ToolkitBrandingValue <Key>` | Your branding values |
| `Get-ToolkitSecret 'Name'` | A value from the wizard's **Secrets** page, or `$null` while the kit is still locked. Never log or display it. |
| `foreach ($sb in Get-ToolkitModuleScripts) { . $sb }` | Load all modules (including unlocked ones that only exist in memory) inside your own runspace |
| `$Global:SyncHash` | Shared state: `.Window`, `.Toolkit` (`Root`, `Parent`, `Version`, `Authenticated`, `IsUsb`), `.ActionContent` |

If you need something that isn't on this list, ask the toolkit provider to add it to core. Don't patch core: builds refuse modified core files.

**Rules that keep the toolkit fast and safe:**
- **Only functions at the top level of the file.** Module files load at every launch and in every background task.
- **Long work goes in the background** (`Start-ModuleInBackground`), never on the UI thread.
- **The toolkit may run as SYSTEM** (ConnectWise backstage). No `Read-Host`, no `HKCU` / user-profile paths, no mapped drives.
- **Never write under `dependencies\`.** Use `Get-ToolkitClientDataPath` or `C:\_INFO\`.
- **No secrets in module files.** List the names in `Secrets = @(...)`, read them with `Get-ToolkitSecret`, and enter the values on the **Secrets** page. Tick **Lock** for every module that uses one.
- **Locked modules run from memory.** In a locked kit their `.ps1` file isn't on disk. Use `Get-ToolkitClientRoot` for your files (installers, resources), and `Get-ToolkitModuleScripts` to load modules in your own runspace, not a path to your module file.

---

## Secrets and locked kits

**Secrets page.** Add a name (for example `RmmSiteKey`) and its value. A module reads it with `Get-ToolkitSecret 'RmmSiteKey'`.

- **Import secrets from module...** reads a module file and adds every secret it needs (its `Secrets = @(...)` list and its `Get-ToolkitSecret` calls), so you only type the values. Values you already entered are kept.
- When you add a module that needs secrets on the **Modules** page, the wizard offers to add them for you.
- You enter each value **once per PC**. Every later locked exe and USB uses it automatically.

- On your PC the values are stored in `client\secrets.dat`, encrypted by Windows for **your Windows account on that PC only**. The names are also kept in `client\secrets-names.json` (names only, safe to commit to git).
- **Moving to another PC:** **Export client package** includes the names. Tick **Include secret values** to also include the values, encrypted with a passphrase you choose; **Import** asks for it. Without the values, the wizard tells you which secrets still need one.
- `secrets.dat` is never committed (`.gitignore`), never in a client package, and never in any build.

**What each build contains:**

| Build | Locked modules | Secrets |
|---|---|---|
| `Launch.bat` from your folder | Unlocked (your test environment) | Read from your `secrets.dat` |
| **Build exe + folder** (`EndpointToolkit.exe`, plus a folder you run with `Launch.bat`: `_builds\v<version>_<date>\EndpointToolkit\`) | **Left out** (no password in this build) | **Not included** |
| **Build locked exe** | Encrypted inside the exe | Encrypted inside the exe |
| **Make USB** | Encrypted on the stick | Encrypted on the stick |

**How a locked exe or USB behaves:**
- It opens **without a password**. Unlocked modules work right away. Locked ones show a lock icon and `[LOCKED]`.
- Clicking a locked module (or **USB Toolkit**) asks for the password **once** and unlocks every locked module and the secrets for that session. They are decrypted in memory only, never written to disk.
- A **USB** needs the locked exe's password to create, then gets **its own password**. It only unlocks on that physical stick, so copied files are useless elsewhere. BitLocker To Go protects the stick when it's unplugged.
- Changed toolkit files are refused. If any file under `dependencies\` or `client\` was edited, added or removed, the kit won't unlock ("Kit files were changed"). Rebuild the kit or re-create the USB. Your own files elsewhere on the stick, and installers added to `CustomInstallers`, are fine and can be edited freely.
- A locked USB never self-updates (since core 2.2.1). Re-create the USB from the new version to update it.
- Passwords for locked exes and USB sticks must be at least 8 characters.

**Limits (be aware):**
- Anyone who knows a kit's password can use its secrets, because the toolkit has to use them. Give the password only to technicians who may use them, and change it (rebuild) when someone leaves.
- Unlocked modules and the core stay readable to anyone who can open the exe. Lock anything that should stay private.
- The changed-files check catches accidental or casual edits, but someone who can rewrite the kit's files can also rewrite the check. What protects a USB is BitLocker To Go. Keep sticks and exes where only your technicians can change them.
- Your own update feed's releases (`latest.zip`) contain your `client\` folder **in plain form, without secrets**. Keep that repo private if your locked modules are sensitive.

---

## Updates

Chosen on the wizard's **Updates** page (`UpdateSource` in `branding.json`):

| Option | What USB toolkits do |
|---|---|
| **Automatic core updates** (`core`, recommended) | Download new **core** versions from the toolkit provider and **keep your `client\` folder**. No GitHub needed. The technician is asked before every update. |
| **My own update feed** (`custom`) | Use your own https feed (`UpdateBaseUrl`) that serves `version.txt`, `latest.zip` and `latest.sha256`, such as a public GitHub repo's Releases, Azure Blob or S3. Your releases must contain your `client\` folder, and the toolkit refuses one that doesn't. |
| **No automatic updates** (`none`) | Nothing is downloaded. Rebuild your exe or USB yourself. |

Every update is verified against its SHA-256 checksum before it is applied.

**Updating your own copy (the folder you build from):**
1. In the wizard, **Check & Build → Export client package...** saves a backup of your `client\` folder as a zip.
2. Extract the new `client-kit.zip` to a new folder.
3. Run `Setup-Client.bat` there and choose **Import client package...** on the Welcome page. You can also copy your old `client\` folder in.
4. Check, then rebuild. The wizard raises your version automatically when you build again.

---

## branding.json reference

The wizard writes this file for you. These are the keys if you edit it by hand:

| Key | Meaning | Default |
|---|---|---|
| `ProductName` | Window title, header, console title, session report, SFX dialog | `Endpoint Toolkit` |
| `AccentColor` | Highlight color, `#RRGGBB` | `#89B4FA` |
| `Logo` | Image path relative to `client\`, PNG ≤ 256 KB, shown about 28 px tall | none |
| `SupportContact` | Shown in the log and Session Report | none |
| `UpdateSource` | `core` / `custom` / `none` (see above) | `custom` if `UpdateBaseUrl` is set, else `none` |
| `UpdateBaseUrl` | Your feed for `UpdateSource: custom` | none |
| `DisabledModules` | Module `Name`s to hide | `[]` |
| `LockedModules` | Module `Name`s that need the password, or `["*"]` for all | `[]` |
| `ExeName` | Renames the built exes. **Leave empty**: ConnectWise Toolbox entries use the default names | `EndpointToolkit` |

Core module names: `Software-Manager`, `Windows-Debloat`, `Computer-Management`, `Network-Diagnostics`, `Storage-Management`, `Crashfinder`, `System-Repair`, `Migration-Assist`.

A mistake in `branding.json` never stops the toolkit from starting. It uses the default and logs a warning.

---

## Command line (optional)

| Command | Does |
|---|---|
| `.\tools\Test-ClientOverlay.ps1` | Runs every check the wizard runs (overlay, modules, core integrity) |
| `.\build.ps1 -SFX` | Zip + `_builds\EndpointToolkit.exe` |
| `.\build.ps1 -SFX -Folder` | Same, plus a ready-to-run folder (`_builds\v<version>_<date>\EndpointToolkit\Launch.bat`). This is what the wizard's **Build exe + folder** runs |
| `-OutputPath D:\Builds` | With `build.ps1` or `Export-LockedToolkit.ps1`: write the builds there instead of `_builds\` (must be outside the toolkit folder) |
| `.\dependencies\Agent\Export-LockedToolkit.ps1` | `EndpointToolkit_Locked.exe` (asks for password and folder) |
| `.\build.ps1 -Test` | Copies to `_builds\` and launches, for a quick test |

---

## Advanced: using GitHub

Use this if you want version control, automatic core-update pull requests, and your own releases and client pack. Create an empty **private** repo first, then:

```powershell
git clone https://github.com/abyssalsoldier/technician-toolkit.git acme-toolkit   # clone, don't download: shared history = clean updates
cd acme-toolkit
git remote rename origin upstream
git remote add origin https://github.com/acme-it/acme-endpoint-toolkit.git        # your empty private repo
git push -u origin main
git checkout -b dev; git push -u origin dev         # day-to-day work happens on dev
.\Setup-Client.bat                                  # create client\ with the wizard
git add client; git commit -m "Add Acme client"; git push
```

Then in the repo's **Settings → Actions → General**, tick **Allow GitHub Actions to create and approve pull requests**.

**How it works:**

| Branch | What happens there |
|---|---|
| `dev` | Your work: modules, branding, wizard changes. Core updates arrive here as pull requests. Pushing publishes nothing. |
| `main` | Releases. Merging `dev` into `main` with a higher `client\version.txt` publishes a release. |

- **Core updates (automatic):** every Monday the **Core update** workflow checks for a new core. If there is one, it opens a pull request into `dev` named **Update core to v\<version\>**. That pull request merges the core, bumps `client\version.txt` if your current version was already released, and shows the overlay checks. Merge it, test, then merge `dev` into `main` to release. You can also start it any time from the **Actions** tab.
  - If you edited a core file, the update takes the core's version and the pull request lists the file. Keep changes in `client\`.
  - When a core update changes a GitHub workflow file, GitHub needs a token with workflow rights to push it. Add a fine-grained token for your repo (Contents, Pull requests and Workflows: read and write) as the Actions secret **`CORE_UPDATE_TOKEN`**. Without it you get an issue with the manual steps instead.
- **Releases:** pushing a version bump to `main` (or `master`, if your repo still uses it) runs the checks and publishes to *your* repo's Releases: `latest.zip`, the ready-to-run exe (both without locked modules), and **`client-kit.zip`**.
  - **Your client pack (`client-kit.zip`):** the core of that release plus `Setup-Client.bat`, the wizard and your whole `client\` folder, including locked modules. Download it from your latest release to set up on a new PC: extract, run `Setup-Client.bat`, then type the secret values again on the Secrets page (secrets are never stored in the pack). It's kept as long as the release exists.
  - It's only attached when the repo is **private**, because it contains your locked modules' code. A public repo gets a warning instead.
  - The release warns when it's built on an older core than the latest one.
- **USB updates:** a private repo's releases need a GitHub sign-in, so USB sticks can't update from them. Use **Automatic core updates** (USB sticks get new cores and keep your `client\`), or host a feed yourself.
- **Updating core by hand:** `git fetch upstream --prune`, then `git merge upstream/main`, then `.\tools\Test-ClientOverlay.ps1 -CheckCore`, then bump your version and push. If you only changed `client\`, the merge is always clean.

---

## Golden rules

1. Change only `client\`, ideally through the wizard.
2. Run the checks (wizard **Check everything**, or `Test-ClientOverlay.ps1`) before building.
3. Never commit or ship passwords, keys, `.toolkit-key` or `.sfx-key` files.
4. Keep `client\` small. It ships in every exe and USB, and ConnectWise uploads it to every machine.

---

## Changelog

### Core 2.2.2
- Changed: the core's release branch is now **`main`** (it was `master`; day-to-day core work is on `dev`). GitHub client repos update with `git fetch upstream --prune` and `git merge upstream/main`. Your own repo can keep releasing from `master`.
- New: every release also has the ready-to-run **`EndpointToolkit.exe`**, next to `latest.zip` and `client-kit.zip`.
- New (GitHub client repos): the **Core update** workflow opens a weekly pull request into `dev` when a new core is out. Private client repos get their own **`client-kit.zip`** (core plus their `client\` folder) with every release. Releases built on an older core show a warning. See **Advanced: using GitHub**.
- New: a download page (`website/`) for the exe, `latest.zip` and `client-kit.zip`.

### Core 2.2.1 (security fixes)
- Fixed: under ConnectWise / SYSTEM, another user of the PC could prepare `C:\Windows\Temp\EndpointToolkit_SC` so their code ran as SYSTEM when the exe started. The exe now refuses to start if that folder can't be removed and secured. **Rebuild your exes and replace them in ConnectWise Toolbox.**
- Fixed: a locked kit with no locked modules or secrets accepted some wrong passwords. Key files (`.sfx-key`, `.toolkit-key`) now use a random salt and a tamper check. Kits made with older versions keep working, and the wrong-password problem is fixed for them too, but rebuild them to get the stronger key file.
- Fixed: a kit with edited core files could still unlock by also editing `core-manifest.json`. Because of this, **locked USB sticks no longer self-update**: re-create them from the new version.
- Fixed: the USB self-update now uses a new, unique temp folder each time.
- Fixed: the release workflow no longer pastes `ProductName` or the version into shell commands.
- Changed: passwords for locked exes and USB sticks must be at least 8 characters.
- New: the wizard's **Build exe + folder** (was **Build exe**) also makes a ready-to-run folder, `_builds\v<version>_<date>\EndpointToolkit\`, that you start with its `Launch.bat`. From the command line: `.\build.ps1 -Folder`.
- Changed: the plain exe, folder build and zip (`build.ps1` without `-Dev`/`-Test`) **leave out locked modules**, because they have no password. Before, they included them unprotected. Ship locked modules with **Build locked exe** or a USB.
- New: locked modules show a lock icon in the menu, as well as `[LOCKED]`.
- New: **Output folder** on the Check & Build page (with **Browse...** and **Default**) chooses where the exe, folder build and locked exe go. Command line: `-OutputPath`.
- New: modules list the secrets they need with `Secrets = @('Name', ...)` in their Register function. The Secrets page has **Import secrets from module...**, and adding a module offers to add its secrets. The checks warn when a module reads a secret it doesn't list.

### Core 2.2.0
- New: **Secrets page** in the wizard and `Get-ToolkitSecret`. Values are protected by Windows on your PC and encrypted into locked exe/USB builds (see [Secrets and locked kits](#secrets-and-locked-kits)).
- New: **locked modules are encrypted** in the locked exe and on USB sticks. Before, the locked exe was a plain zip that anyone could open with 7-Zip, and deleting one hidden file unlocked it. Now the locked code and secrets can't be read without the password, and a kit with changed files refuses to unlock.
- Changed: the locked exe and USB **open without a password**. The password is asked when a locked module (or USB Toolkit) is first clicked, and unlocks all of them.
- Changed: a USB made from the locked exe no longer accepts the exe's password, only its own.
- Changed: the locked exe removes its extracted copy (`%TEMP%\EndpointToolkit_SC`) on exit and restricts who can open it.
- New: `Get-ToolkitModuleScripts` for loading modules in your own runspace.
- Fixed: the locked exe could not extract itself (".NET: Number of entries expected in End Of Central Directory..."). Rebuild existing locked exes.
- Fixed: the toolkit crashed when it started locked (lock icon).
- Note: locked exes and USB sticks made with older versions keep working, but their modules aren't encrypted. Rebuild them to get the protection.

### Core 2.1.1
- Changed: the core repo is now `abyssalsoldier/technician-toolkit` (was `Endpoint-toolkit`). The default update feed points at the new name. GitHub redirects the old URL, so existing USB sticks keep updating. Client repos should run `git remote set-url upstream https://github.com/abyssalsoldier/technician-toolkit.git`.

### Core 2.1.0
- New: **Client Setup wizard** (`Setup-Client.bat`). Branding with a live preview, add/create/remove modules, Show and Lock per module, installers, update mode, checks, building the exe and locked exe, USB, export/import of client packages. No GitHub needed.
- New: **Export guide for AI agent** on the wizard's Modules page (a self-contained module-writing brief as `.md`).
- New: **`LockedModules`**. Lock any core or client module behind the password, per client (default: nothing locked).
- New: **`UpdateSource`**. `core` gives automatic core updates that keep `client\`; `custom` uses your own feed; `none` turns updates off.
- New: **core integrity manifest** (`dependencies\core-manifest.json`). Builds refuse modified core files.
- New: module checks when adding modules (no execution); `MinCoreVersion`; `Get-ToolkitClientDataPath`.
- New: `client-kit.zip` release asset for setting up without GitHub.
- Fixed: the locked exe export failed under Windows PowerShell 5.1 (C# compile error).

### Core 2.0.0
- New: client overlay (`client\`) for branding, modules, installers and a per-client version.
- A client module can replace a core module with the same `Name`. `tools\Test-ClientOverlay.ps1` validator.
- USB self-update respects the client's feed and refuses releases that would remove `client\`.
- Unchanged: entry points, exe names, temp folders and cleanup. ConnectWise Toolbox usage is unchanged.
