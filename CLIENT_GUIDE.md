# Client Guide: Running Your Own Branded Toolkit

This guide is for IT teams who run their own copy of the Endpoint Toolkit with their own name, colors, modules and update feed. It assumes you are comfortable with Git and PowerShell. If you use an AI coding agent, point it at [AGENTS.md](AGENTS.md). It contains the same rules in a form agents follow.

---

## How it works

Your repository has two parts:

| Part | Where | Who changes it |
|---|---|---|
| **Core** | Everything **except** `client/` (`dependencies/`, `Launch.bat`, `build.ps1`, `tools/`, ...) | Only the core maintainers. You receive core changes by merging. |
| **Client overlay** | `client/` | You. Your branding, your modules, your installers, your version number. |

Your repo is a copy of the core repo with the core added as a Git remote called `upstream`. The core repo never contains a `client/` folder, so **merging a new core version never conflicts with your changes**, as long as you only change files inside `client/`.

At launch, the toolkit reads `client/` from its own folder. This works the same way for every launch method: `Launch.bat`, a USB stick, the SFX `.exe`, the password-locked `.exe`, or a ConnectWise Control Toolbox run. Nothing is compiled into the exe. If `client/` is missing, the toolkit runs as the plain core version.

```text
your-toolkit-repo/
├── client/                      ← yours
│   ├── branding.json            product name, accent color, logo, support contact, update feed
│   ├── version.txt              YOUR release version (e.g. 1.4.0)
│   ├── logo.png                 optional, PNG ≤ 256 KB, shown in the title bar
│   ├── Modules/                 your modules (e.g. RMM-Agent.ps1)
│   └── CustomInstallers/        your installers (shown in Software Manager)
├── client.example/              template to copy (core, not shipped)
├── dependencies/                core
├── tools/Test-ClientOverlay.ps1 checks your overlay (core, not shipped)
└── ...
```

---

## One-time setup

You need read access to the core repository. Your toolkit provider gives you this.

```powershell
# 1. Clone the core. Clone it, don't download a zip: the shared Git history is what makes updates merge cleanly.
git clone https://github.com/abyssalsoldier/Endpoint-toolkit.git acme-toolkit
cd acme-toolkit

# 2. Make the core the "upstream" remote, and your own (private) repo the "origin"
git remote rename origin upstream
#    Create an EMPTY repository on GitHub first, e.g. acme-it/acme-endpoint-toolkit
git remote add origin https://github.com/acme-it/acme-endpoint-toolkit.git
git push -u origin master

# 3. Create your overlay from the template
Copy-Item client.example client -Recurse
#    Edit client\branding.json and client\version.txt (see below)
#    Delete client\Modules\Example-Module.ps1 once you have your own modules

# 4. Check it, commit it
.\tools\Test-ClientOverlay.ps1 -CheckCore
git add client
git commit -m "Add Acme client overlay"
git push
```

Test locally with `.\build.ps1 -Test`. It copies the toolkit to `_builds\` and launches it.

---

## Branding (`client/branding.json`)

```json
{
  "ProductName": "Acme Endpoint Toolkit",
  "AccentColor": "#F38BA8",
  "Logo": "logo.png",
  "SupportContact": "helpdesk@acme.example / 555-0100",
  "UpdateBaseUrl": "https://github.com/acme-it/acme-endpoint-toolkit/releases/latest/download",
  "DisabledModules": ["Migration-Assist"],
  "ExeName": ""
}
```

| Key | What it does | Default |
|---|---|---|
| `ProductName` | Window title, header, console title, session report, SFX dialog title | `Endpoint Toolkit` |
| `AccentColor` | Highlight color for headers, buttons and links across the UI. Format `#RRGGBB`. | `#89B4FA` |
| `Logo` | Image path **relative to `client/`**, shown left of the product name. PNG, ≤ 256 KB, about 28 px tall. | none |
| `SupportContact` | Shown in the log at startup and in the Session Report | none |
| `UpdateBaseUrl` | Where USB toolkits look for updates (see [Releases and updates](#releases-and-updates)). Must be `https://`. **Empty = USB self-update is off.** | none (a client build never uses the core feed) |
| `DisabledModules` | Core (or client) module `Name`s to hide from the menu | `[]` |
| `ExeName` | Renames the built exe (`<ExeName>.exe`, `<ExeName>_Locked.exe`). **Leave empty** unless you want new names. ConnectWise Toolbox entries point at the existing names. | `EndpointToolkit` |

Core module names you can disable: `Software-Manager`, `Windows-Debloat`, `Computer-Management`, `Network-Diagnostics`, `Storage-Management`, `Crashfinder`, `System-Repair`, `Migration-Assist`.

A mistake in `branding.json` never stops the toolkit from starting. The toolkit falls back to the default for that value and logs a warning in the log panel. `tools\Test-ClientOverlay.ps1` reports these mistakes before you ship.

---

## Writing a module

Start from `client.example/Modules/Example-Module.ps1`. A module is one `.ps1` file in `client/Modules/` with a `Register-<Something>` function:

```powershell
function Register-AcmeRmm {
    @{
        Name         = 'Acme-RMM'            # unique ID. Reusing a core Name REPLACES that core module.
        Label        = 'RMM Agent'           # menu text
        Description  = 'Install and check the Acme RMM agent'
        RequiresAuth = $true                 # locked until the toolkit password is entered
        SortOrder    = 60                    # menu position (core modules use 20-50)
        EntryPoint   = 'Start-AcmeRmm'       # runs in a background runspace
        UIDefinition = 'Get-AcmeRmmUI'       # optional: your own panel. Without it you get a "Run" button.
    }
}
```

Rules that keep the toolkit fast and safe:

- **Only functions at the top level of the file.** Module files are loaded at every launch and in every background task. Code outside a function runs every time.
- **Long work goes in the background.** Call `Start-ModuleInBackground -Module (Register-AcmeRmm)` from a button. It runs your `EntryPoint` in a runspace and records it in the Session Report. Inside it, use `Write-Log '...' -Level Info|Success|Warning|Error`.
- **The toolkit may run as SYSTEM** (ConnectWise backstage). Don't rely on the user profile, mapped drives or prompts.
- **Use the brand color:** `New-ToolkitBrush` (accent) or `New-ToolkitBrush '#A6ADC8'`, `Get-ToolkitAccent`. Don't hardcode `#89B4FA`.
- **Find your files** with `Get-ToolkitClientRoot`, for example `Join-Path (Get-ToolkitClientRoot) 'CustomInstallers\agent.msi'`.
- **No secrets in the repo.** RMM site keys, tenant tokens and passwords should be typed in by the technician, or kept out of a public feed. Everything in `client/` ships to every machine the toolkit runs on.

Installers in `client/CustomInstallers/` show up in Software Manager under **Custom Installers**, next to the core ones.

---

## Releases and updates

Your repo includes the core GitHub Actions workflow (`.github/workflows/release.yml`). In your repo it:

1. reads **`client/version.txt`** (not the core version)
2. runs `tools/Test-ClientOverlay.ps1` (the release fails if your overlay has errors)
3. builds `latest.zip` (including `client/`; excluding the repo-only docs, `tools/` and `client.example/`)
4. publishes release `v<your version>` to **your** repo

**To ship:** bump `client/version.txt`, commit, push to `master`. A push that doesn't change the version publishes nothing.

USB toolkits check `UpdateBaseUrl` at launch, download `version.txt`, `latest.zip` and `latest.sha256` from it, verify the SHA-256, and mirror the update onto the stick. Two safety rules apply:

- A client toolkit **refuses** an update that doesn't contain a `client/` folder, so it can't be overwritten by a plain core release.
- The update check is unauthenticated. **Releases in a private GitHub repo can't be downloaded this way.** Either publish releases from a public repo, or host the three files on any HTTPS location you control (Azure Blob, S3, a web server) and point `UpdateBaseUrl` at that folder. If your client modules contain anything sensitive, use a private hosted location, not a public repo.

Builds for distribution (unchanged from core):

| Command | Output |
|---|---|
| `.\build.ps1` | `_builds\v<version>_<time>\endpoint-build-toolkit.zip` + `latest.sha256` |
| `.\build.ps1 -SFX` | `_builds\EndpointToolkit.exe` (self-extracting, for ConnectWise Toolbox) |
| `dependencies\Agent\Export-LockedToolkit.ps1` | `EndpointToolkit_Locked.exe` (password-protected) |
| **USB Toolkit** button in the app | BitLocker-protected USB stick |

---

## Updating the core

```powershell
git fetch upstream
git merge upstream/master
.\tools\Test-ClientOverlay.ps1 -CheckCore     # must pass
.\build.ps1 -Test                             # quick smoke test
# bump client\version.txt so your devices receive the new core
git commit -am "Update core to vX.Y.Z"
git push
```

If you only changed files in `client/`, the merge is always clean. If Git reports a conflict in a file outside `client/`, someone edited core. Take the core version with `git checkout --theirs <file>` and move your change into `client/`. If that isn't possible, ask the core maintainers to add a hook for it.

`Test-ClientOverlay.ps1 -CheckCore` fails whenever a file outside `client/` differs from the core. It also tells you when new core commits are waiting to be merged.

---

## Golden rules

1. Change **only** `client/`. Need something in core changed? Ask the core maintainers. Don't patch it locally.
2. Run `.\tools\Test-ClientOverlay.ps1 -CheckCore` before every commit.
3. Bump `client/version.txt` for every release, including core updates.
4. Never commit passwords, keys, `.toolkit-key` or `.sfx-key` files.
5. Keep `client/` small. It ships in every zip, exe and USB, and ConnectWise Toolbox uploads it to every machine.

---

## Changelog

### Core 2.0.0
- New: client overlay (`client/`) for branding, modules, installers and a per-client version.
- New: `client/branding.json` (product name, accent color, logo, support contact, update feed, disabled modules, exe name).
- New: client modules in `client/Modules/`. A client module can replace a core module with the same `Name`.
- New: `tools/Test-ClientOverlay.ps1` validator, also run by the release workflow.
- New: the release workflow uses `client/version.txt` and the product name when present.
- USB self-update uses the client's `UpdateBaseUrl` and refuses releases that would remove `client/`.
- Unchanged: entry points, exe names, temp folders and cleanup. ConnectWise Toolbox usage is unchanged.
