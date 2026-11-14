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
   4. **Installers:** add your `.exe`/`.msi` installers, for example your RMM agent.
   5. **Updates:** choose how USB toolkits update (see [Updates](#updates)).
   6. **Check & Build:** run the checks, then **Build exe**, **Build locked exe** or **Make USB**.
4. Your builds are in `C:\Toolkit\_builds\`. The exe names stay `EndpointToolkit.exe` and `EndpointToolkit_Locked.exe`, so existing ConnectWise Toolbox entries keep working.

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
| `$Global:SyncHash` | Shared state: `.Window`, `.Toolkit` (`Root`, `Parent`, `Version`, `Authenticated`, `IsUsb`), `.ActionContent` |

If you need something that isn't on this list, ask the toolkit provider to add it to core. Don't patch core: builds refuse modified core files.

**Rules that keep the toolkit fast and safe:**
- **Only functions at the top level of the file.** Module files load at every launch and in every background task.
- **Long work goes in the background** (`Start-ModuleInBackground`), never on the UI thread.
- **The toolkit may run as SYSTEM** (ConnectWise backstage). No `Read-Host`, no `HKCU` / user-profile paths, no mapped drives.
- **Never write under `dependencies\`.** Use `Get-ToolkitClientDataPath` or `C:\_INFO\`.
- **No secrets in files.** RMM site keys, tenant tokens and passwords should be typed in by the technician. Everything in `client\` ships to every machine the toolkit runs on.

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
| `.\dependencies\Agent\Export-LockedToolkit.ps1` | `EndpointToolkit_Locked.exe` (asks for password and folder) |
| `.\build.ps1 -Test` | Copies to `_builds\` and launches, for a quick test |

---

## Advanced: using GitHub

Use this if you want version control and your own release feed:

```powershell
git clone https://github.com/abyssalsoldier/Endpoint-toolkit.git acme-toolkit   # clone, don't download: shared history = clean updates
cd acme-toolkit
git remote rename origin upstream
git remote add origin https://github.com/acme-it/acme-endpoint-toolkit.git        # your empty repo
git push -u origin master
.\Setup-Client.bat                                  # create client\ with the wizard
git add client; git commit -m "Add Acme client"; git push
```

- **Releases:** the included workflow (`.github/workflows/release.yml`) builds from `client\version.txt`, runs the checks, and publishes to *your* repo's Releases when you push a version bump to `master`. Set Updates to "My own update feed" with `https://github.com/<you>/<repo>/releases/latest/download`. The feed must be **public**, because USB toolkits download without signing in. Otherwise use automatic core updates or host the files yourself.
- **Updating core:** `git fetch upstream`, then `git merge upstream/master`, then `.\tools\Test-ClientOverlay.ps1 -CheckCore`, then bump your version and push. If you only changed `client\`, the merge is always clean.

---

## Golden rules

1. Change only `client\`, ideally through the wizard.
2. Run the checks (wizard **Check everything**, or `Test-ClientOverlay.ps1`) before building.
3. Never commit or ship passwords, keys, `.toolkit-key` or `.sfx-key` files.
4. Keep `client\` small. It ships in every exe and USB, and ConnectWise uploads it to every machine.

---

## Changelog

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
