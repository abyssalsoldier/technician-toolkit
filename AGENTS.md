# Agent Instructions: Endpoint Toolkit

PowerShell 5.1+ / WPF endpoint toolkit for MSP technicians. It runs from `Launch.bat`, a USB stick, a self-extracting exe, or a **ConnectWise Control Toolbox** upload, sometimes as SYSTEM. The human-facing version of these rules is [CLIENT_GUIDE.md](CLIENT_GUIDE.md).

## 1. Work out which repo you are in

```powershell
git remote -v
Test-Path client
```

- **Client repo:** an `upstream` remote points at the core repo (`abyssalsoldier/technician-toolkit`) and/or a `client/` folder exists. Follow **section 2**.
- **Core repo:** `origin` is the core repo and there is no `client/` folder. Follow **section 6**.

If it's unclear, ask the user before editing anything.

## 2. Client repo: hard boundary

**Edit only files under `client/`.** Everything else is core and is replaced on every core update.

- Don't edit, rename, reformat or delete files outside `client/`. That includes `dependencies/`, `Launch.bat`, `build.ps1`, `tools/`, `.github/`, `README.md`, and this file.
- If a task seems to need a core change, stop. Tell the user what core hook is missing and suggest they ask the core maintainers. Don't patch core "temporarily".
- Core files are checksummed in `dependencies/core-manifest.json`. `build.ps1`, `Export-LockedToolkit.ps1`, the wizard and CI **refuse to build** a client toolkit when any core file differs. Never edit or regenerate that manifest in a client repo, and never pass `-AllowModifiedCore` (core maintainers only).
- The Client Setup wizard (`Setup-Client.bat`) is the normal way for humans to change `client/`. Agents may edit `client/` files directly, but must keep `branding.json` valid for the wizard (known keys only; `_`-prefixed keys are comments).
- Override core behavior only through the supported mechanisms:
  - `client/branding.json`: ProductName, AccentColor, Logo, SupportContact, UpdateSource (`core`/`custom`/`none`), UpdateBaseUrl, DisabledModules, LockedModules (`["*"]` = all), ExeName
  - a client module whose `Name` equals a core module `Name` replaces that module
  - a client function with the same name as a core function replaces it (last resort, tell the user; it can break on core updates)

## 3. Client repo: procedures

### Update the core
```powershell
git status                                  # must be clean first
git fetch upstream
git merge upstream/main                     # clean if the boundary was respected (the core branch was master before v2.2.1)
.\tools\Test-ClientOverlay.ps1 -CheckCore   # must exit 0
```
- **Conflict in a path outside `client/`:** resolve with `git checkout --theirs -- <path>` (take core), then `git add <path>`. Never keep a local version of a core file. Tell the user which files conflicted, because a local core edit existed.
- **Conflict inside `client/`:** shouldn't happen, since core never ships `client/`. Stop and ask the user.
- After the merge, bump `client/version.txt` (see below), commit as `Update core to v<dependencies/version.txt>`, and push only if the user asks.
- If `upstream` is missing: `git remote add upstream https://github.com/abyssalsoldier/technician-toolkit.git`

### Ship a release
Bump `client/version.txt` (semantic version, always higher than the last release), commit, and push to your release branch (`main`, or `master` in client repos created before v2.2.1). CI publishes `v<version>` to this repo's Releases. Bump the patch for fixes and core updates, the minor for new modules or features, the major for breaking changes to how technicians use the toolkit.

### Before every commit
```powershell
.\tools\Test-ClientOverlay.ps1 -CheckCore
```
Exit code 1 means errors. Fix them, don't bypass them. Read the warnings and mention them to the user.

## 4. Writing a client module

File: `client/Modules/<Name>.ps1`. Template: `client.example/Modules/Example-Module.ps1`.

```powershell
function Register-AcmeRmm {
    @{
        Name         = 'Acme-RMM'          # required, unique (a core Name = replace that module)
        Label        = 'RMM Agent'         # required, menu text
        Description  = '...'
        RequiresAuth = $true               # true for anything that changes the machine or uses credentials
        SortOrder    = 60                  # required number; core uses 20-50
        EntryPoint   = 'Start-AcmeRmm'     # required, function in this file, runs in a background runspace
        UIDefinition = 'Get-AcmeRmmUI'     # optional, function returning a WPF UIElement
        MinCoreVersion = '2.1.0'           # optional, the module is skipped on older cores
        Secrets      = @('AcmeRmmSiteKey') # every secret it reads with Get-ToolkitSecret (omit or @() for none)
    }
}
```
Keep `Name`, `EntryPoint`, `UIDefinition` and `SortOrder` as **plain literal values**. The validator reads them without running the file, and it rejects computed values. Prefix every function name with your company (`Get-AcmeRmmUI`). Reusing a core function name is rejected unless the module intentionally replaces that core module (same `Name`).

Available helpers (from `dependencies/Core/ClientOverlay.ps1` and `dependencies/UI/`):

| Helper | Use |
|---|---|
| `Start-ModuleInBackground -Module (Register-X)` | run the EntryPoint in a runspace, recorded in the Session Report |
| `Write-Log '<msg>' -Level Info\|Success\|Warning\|Error` | log panel (works in runspaces) |
| `New-ToolkitBrush [<'#RRGGBB'>]`, `Get-ToolkitAccent` | brand-colored brushes. Never hardcode `#89B4FA`. |
| `Get-ToolkitClientRoot` | full path of `client/` at runtime (it may be a temp copy) |
| `Get-ToolkitClientDataPath ['sub']` | working folder for files a module writes during a session (not persistent). Durable output goes to `C:\_INFO\<Module>` |
| `Get-ToolkitProductName`, `Get-ToolkitBrandingValue <Key>` | branding values |
| `Get-ToolkitSecret '<Name>'` | a value from the wizard's Secrets page (`$null` while the kit is locked). Never log, display or write it. |
| `foreach ($sb in Get-ToolkitModuleScripts) { . $sb }` | load every module in your own runspace, including locked ones that only exist in memory |
| `$Global:SyncHash` | shared state: `.Window`, `.Toolkit` (Root, Parent, Version, Authenticated, IsUsb), `.ActionContent` |

Required behavior:
- **Only function definitions at the top level.** Modules are dot-sourced at every launch and in every runspace. Load-time code slows every run.
- **Never block the UI thread.** Anything longer than a moment runs via `Start-ModuleInBackground` or a runspace that loads `Core`, `UI` and the module files. Update controls only through `$SyncHash.Window.Dispatcher.Invoke(...)`.
- **ConnectWise Toolbox / SYSTEM safe:** no `Read-Host`, no console prompts, no `$env:USERPROFILE` or `HKCU` assumptions, no mapped drives. Use WPF controls for input.
- **Lightweight:** no new PowerShell modules from the Gallery, no large binaries unless the user asks. Installers go in `client/CustomInstallers/`. Warn the user about anything over ~25 MB.
- **Never write, move or delete anything under `dependencies/`** or elsewhere in core. The validator scans for this, and the manifest catches anything it misses. Use `Get-ToolkitClientDataPath` or `C:\_INFO\`. If the module API above doesn't cover what's needed, tell the user it needs a core feature. Don't work around it.
- **No secrets** in code or files: no RMM tenant or site keys, tokens or passwords. List each one in the Register `Secrets = @(...)` key (plain quoted names), read it with `Get-ToolkitSecret '<Name>'`, and set `RequiresAuth = $true` (or tell the user to tick Lock). Tell the user the exact names and what value each takes; the wizard's **Import secrets from module...** button (Secrets page) adds them from the `Secrets` list. Never touch `client/secrets.dat` (Windows DPAPI, per user) and never commit it.
- **Locked modules run from memory.** In a locked exe or USB their `.ps1` is inside an encrypted vault (`client/.locked/vault.bin`), not on disk. Never build paths from the module file's own location, and load modules in a runspace with `Get-ToolkitModuleScripts`, not by file path.
- Paths: build them with `Join-Path`. Never hardcode a drive letter or the toolkit folder. Client files (installers, resources) are under `Get-ToolkitClientRoot`, not `$toolkitRoot\Modules`.

## 5. Things not to do (either repo)

- Don't change entry points or runtime layout: `Launch.bat`, `dependencies\Invoke-EndpointSetup.ps1` (path and parameters), the SFX bootstrap, the temp folder names `EndpointToolkit_SC` / `EndpointToolkit_<guid>`, the cleanup routine, or the exe names. ConnectWise Toolbox entries and existing USB sticks depend on them.
- Don't hardcode the update URL. It comes from `branding.json` (client) or `Get-ToolkitCoreDefaults` (core).
- Don't point a client's `UpdateBaseUrl` at the core release feed.
- Don't commit `*.key`, `.toolkit-key`, `.sfx-key`, `client/secrets.dat`, `client/secrets.pkg`, `_builds/` or zips. (`client/secrets-names.json` holds names only and may be committed.)
- Don't push, tag or publish releases unless the user asks. A push to `main` (or `master` in an older client repo) with a bumped version publishes a release automatically.

## 6. Core repo (maintainers)

The core is the source of truth for every client. Clients merge it without reviewing it, so:

- **Regenerate the core manifest after every core change:** `.\build.ps1 -UpdateCoreManifest`, then commit `dependencies/core-manifest.json` with the change. CI fails when it's stale. In a core checkout, builds only warn about a stale manifest, so day-to-day work isn't blocked.
- **The module API is the contract.** The functions listed in section 4 plus `branding.json` keys are what clients build on. Add to them (new helpers, new keys) instead of telling clients to patch core. Breaking changes bump `OverlayApiVersion` in `Get-ToolkitCoreDefaults` and the major version.
- New repo-only files must also be added to `Get-ToolkitPayloadExcludes` and the release.yml exclusions (the wizard, `Setup-Client.bat`, `tools/`, `client.example/`, the docs, `client/_removed`, `client/Data` are already there).
- **Never commit a `client/` folder to core.** Test with a local `client/` (copy `client.example`) and delete it before committing.
- **Keep the overlay API backward compatible:** the `Register-*` keys, the branding keys, and the public functions in `dependencies/Core/ClientOverlay.ps1` (`Get-ToolkitClientRoot`, `Get-ToolkitBranding*`, `Get-ToolkitAccent`, `New-ToolkitBrush`, `Get-ToolkitModuleFiles`, `Get-ToolkitModuleScripts`, `Get-ToolkitModulePaths`, `Get-ToolkitInstallerPaths`, `Get-ToolkitPayloadExcludes`, `Get-ToolkitVersionInfo`), `Get-ToolkitSecret` (LockedKit.ps1), plus `Start-ModuleInBackground` and `Write-Log`. A breaking change needs a major version bump and a note in the CLIENT_GUIDE changelog.
- **Locked kits** (locked exe, USB): `dependencies/Agent/LockedPayload.ps1` moves locked client modules and the wizard secrets into an encrypted vault with a file manifest; `dependencies/Core/LockedKit.ps1` unlocks it on demand and refuses kits whose files changed. Any new file a kit writes at runtime under `dependencies/` or `client/` must be added to `Test-ToolkitIntegritySkip`, or unlocking fails.
- Load modules through `Get-ToolkitModuleFiles` and installers through `Get-ToolkitInstallerPaths`, so client folders are always included.
- New UI uses `Get-ToolkitAccent` / `New-ToolkitBrush`, not `#89B4FA`. XAML may use `#FF89B4FA`, because `Load-XamlWindow` swaps it for the brand color.
- New repo-only files (docs, tooling) must be excluded from payloads in **both** `Get-ToolkitPayloadExcludes` (ClientOverlay.ps1) and the zip step in `.github/workflows/release.yml`.
- Startup cost matters (ConnectWise Toolbox): nothing new at startup that does network calls, loads assemblies or prompts. Overlay problems become warnings, never failures.
- **Branches:** day-to-day core work goes on `dev`, which publishes nothing. `main` is the release branch: clients merge it, releases and the download site (`website/`) come from it. Never commit straight to `main`.
- Release: bump `dependencies/version.txt` on `dev`, then merge `dev` into `main` and push `main` (only when the user asks). Clients pick it up with `git merge upstream/main`.
- Before committing, run `.\tools\Test-ClientOverlay.ps1` both with and without a test `client/` folder, and `.\build.ps1 -Test`.
