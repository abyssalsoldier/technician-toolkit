# How to write a module for {{ProductName}}

You are an AI coding agent writing a **client module** for {{ProductName}}, a branded build of the Technician Toolkit (core v{{CoreVersion}}). It's a PowerShell 5.1+ / WPF toolkit that MSP technicians run on Windows endpoints from a USB stick, a self-extracting exe, or a **ConnectWise Control Toolbox** upload, sometimes as **SYSTEM**.

This document is self-contained. Follow it exactly. The module will be checked automatically when it is added in the Client Setup wizard, and it is **rejected** if it breaks the rules in [Section 5](#5-checks-the-module-must-pass).

---

## 1. What you deliver

**One `.ps1` file.** The user adds it with **Client Setup → Modules → Add module file...** It is copied to `client\Modules\<FileName>.ps1`. Use your company prefix in the file name, for example `{{Prefix}}-RmmAgent.ps1`.

Optional extras the user adds separately:
- **Installers** (`.exe` / `.msi`) the module uses, added in **Client Setup → Installers**. At runtime they are in `Join-Path (Get-ToolkitClientRoot) 'CustomInstallers\<file>'`.

You can't change anything else. **The core toolkit is read-only.** Every core file is checksummed and builds refuse modified core. If you need something the API in [Section 3](#3-the-module-api-everything-you-may-use) doesn't offer, stop and tell the user it needs a core feature request.

---

## 2. The module contract

A module file contains **only function definitions**, and exactly one `Register-*` function:

```powershell
function Register-{{Prefix}}RmmAgent {
    @{
        Name           = '{{Prefix}}-RmmAgent'      # REQUIRED unique ID (letters, digits, space . _ -)
        Label          = 'RMM Agent'                # REQUIRED menu text
        Description    = 'Install and check the RMM agent'
        RequiresAuth   = $false                     # $true = ALWAYS needs the toolkit password
        SortOrder      = 60                         # REQUIRED number - menu position (core uses 20-50)
        EntryPoint     = 'Start-{{Prefix}}RmmAgent'  # REQUIRED function in this file, runs in the background
        UIDefinition   = 'Get-{{Prefix}}RmmAgentUI'  # optional function in this file, returns a WPF element
        MinCoreVersion = '{{CoreVersion}}'          # optional: skipped on older cores
        Secrets        = @('{{Prefix}}RmmSiteKey')  # REQUIRED when the module reads secrets: every name it passes to Get-ToolkitSecret
    }
}
```

Rules for the hashtable:
- `Name`, `Label`, `EntryPoint`, `SortOrder` are required. `Name`, `EntryPoint`, `UIDefinition` and `SortOrder` must be **plain literal values** (no variables or expressions), because the checker reads them without running the file.
- `EntryPoint` and `UIDefinition` must name functions **defined in the same file**.
- Reusing the `Name` of a core module **replaces** that core module. Only do this when the user asks for it.
- Leave `RequiresAuth = $false` unless the module must always be locked. The user can lock any module per build in the wizard. A module that reads secrets must be locked (`RequiresAuth = $true`, or Lock in the wizard).
- **`Secrets` lists every secret the module needs**, as plain names in quotes: `Secrets = @('{{Prefix}}RmmSiteKey', '{{Prefix}}RmmApiToken')`. Omit the key, or use `@()`, when the module needs none. The wizard reads this list to add the secrets to its **Secrets** page (**Import secrets from module...**, and automatically when the module is added), so the user only types the values. Each name must match the `Get-ToolkitSecret '<Name>'` calls exactly: letters, digits and `_`, starting with a letter.

**How it runs:**
1. At launch, and inside every background task, the toolkit loads core modules first, then client modules, by dot-sourcing them. **Anything at the top level runs every time.**
2. The menu shows `Label`. Clicking it calls `UIDefinition` on the UI thread and shows the returned element. Without a `UIDefinition`, a default panel with a **Run** button calls the `EntryPoint`.
3. `EntryPoint` runs in a **background runspace** with Core, UI helpers and all modules loaded. It's recorded in the Session Report as success, or as error if it throws.

---

## 3. The module API (everything you may use)

| Function / object | Use |
|---|---|
| `Start-ModuleInBackground -Module (Register-X)` | Run your `EntryPoint` in a background runspace from a button, logged in the Session Report. **Use this for any work longer than a moment.** |
| `Write-Log '<text>' -Level Info\|Success\|Warning\|Error` | Write to the log panel. Works on the UI thread and in background tasks. |
| `New-ToolkitBrush` / `New-ToolkitBrush '#RRGGBB'` | WPF brush in the brand accent color ({{AccentColor}}) or a given color |
| `Get-ToolkitAccent` | The brand accent as `'#RRGGBB'`. Never hardcode it. |
| `Get-ToolkitClientRoot` | Full path of the client folder at runtime (often a temp copy) |
| `Get-ToolkitClientDataPath ['subfolder']` | Working folder for files written **during this session**. Wiped on Quit for USB/exe runs. |
| `C:\_INFO\<ModuleName>\` | Where reports and anything that must survive go (the core modules do the same) |
| `Get-ToolkitProductName`, `Get-ToolkitBrandingValue '<Key>'` | Branding values |
| `Get-ToolkitSecret '<Name>'` | A value the user entered on the wizard's **Secrets** page (RMM site key, token, password), or `$null` while the kit is locked. Never log, display or write it to a file. |
| `$Global:SyncHash.Window` | Main window. Use `.Dispatcher.Invoke([action]{ ... })` to update UI from a background task. |
| `$Global:SyncHash.Toolkit` | `.Version`, `.CoreVersion`, `.Authenticated`, `.IsUsb`, `.Root` (read-only use), `.Parent` |
| `$Global:SyncHash.ActionContent` | The content area your `UIDefinition` element is shown in |

Inside a background runspace the shared state is also available as `$SyncHash`. For your own extra runspace, load the toolkit the same way the core does:
```powershell
$toolkitRoot = $SyncHash.Toolkit.Root
Get-ChildItem "$toolkitRoot\Core" -Filter *.ps1 -File | ForEach-Object { . $_.FullName }
Get-ChildItem "$toolkitRoot\UI"   -Filter *.ps1 -File | ForEach-Object { . $_.FullName }
foreach ($sb in Get-ToolkitModuleScripts) { . $sb }   # all modules, including locked ones (they only exist in memory)
```
`Start-ModuleInBackground` is simpler and is preferred.

---

## 4. Rules (ConnectWise / SYSTEM safe, lightweight)

1. **Top level = function definitions only.** No commands, `Add-Type`, network calls or file access outside functions.
2. **Never block the UI thread.** Button handlers start background work, and the background work updates the UI only through `Dispatcher.Invoke`.
3. **No console input:** no `Read-Host`, `pause` or `Get-Credential`. The console is hidden. Ask for input with WPF controls (TextBox, PasswordBox) in your `UIDefinition`.
4. **Assume SYSTEM:** no `HKCU:`, `$env:USERPROFILE`, `$env:APPDATA`, `$HOME`, or mapped drives. Use `HKLM:`, `$env:ProgramData`, `C:\_INFO`.
5. **Never write, move or delete anything in core** (`dependencies\`, `$SyncHash.Toolkit.Root`, the toolkit folder itself). Write only to `Get-ToolkitClientDataPath` or `C:\_INFO\`.
6. **No secrets in the file:** no RMM site keys, tenant tokens, API keys or passwords in the code. List each one in `Secrets = @(...)` in the Register function, read it with `Get-ToolkitSecret '<Name>'` (always a plain quoted name, never a variable), and lock the module. Don't log it. When you hand the module over, tell the user which secrets it needs and what value each one takes (for example "`{{Prefix}}RmmSiteKey`: the site key from the RMM portal, Settings > Sites"). Also put that list in a comment at the top of the file. Locked modules run from memory, so never build a path from your module file's own location; use `Get-ToolkitClientRoot`.
7. **Unique function names:** prefix every function with `{{Prefix}}` (for example `Get-{{Prefix}}RmmAgentUI`). Names already used by core are rejected (see [Appendix B](#appendix-b-function-names-already-used-by-core)).
8. **Lightweight:** no PowerShell Gallery modules, no downloads at load time, nothing large. Put installers in Installers.
9. **PowerShell 5.1 compatible:** the exes run on Windows PowerShell 5.1. No `??`, `?.`, ternary `? :`, `&&`/`||` chaining, `ForEach-Object -Parallel`, or C# 6+ syntax in `Add-Type`.
10. **Fail clearly:** throw or `Write-Log ... -Level Error` with a useful message. An exception in `EntryPoint` marks the Session Report entry as Error.

---

## 5. Checks the module must pass

The wizard parses the file (it never runs it). It **rejects** the module for:
- syntax errors
- no `Register-*` function, or more than one
- a missing `Name`, `Label`, `EntryPoint` or `SortOrder`, or a non-numeric `SortOrder`
- `Name`, `EntryPoint`, `UIDefinition` or `SortOrder` not written as a plain value
- an `EntryPoint` or `UIDefinition` not defined in the file
- a `Name` already used by another client module
- defining a function that already exists in core, unless the module replaces that core module
- writing, moving or deleting under core paths (`Toolkit.Root`, `$toolkitRoot`, `dependencies`, `$PSScriptRoot\..`)
- an invalid `MinCoreVersion`

It **warns** about:
- a `Get-ToolkitSecret '<Name>'` whose name is missing from `Secrets = @(...)`, or a `Secrets` entry that isn't a plain quoted name
- code at the top level
- `Read-Host`
- `HKCU:`, `USERPROFILE`, `APPDATA`, `$HOME`
- a file larger than 1 MB

---

## 6. Template

Start from this and rename every `{{Prefix}}Example` / `{{Prefix}} Example`:

```powershell
{{Template}}
```

---

## Appendix A: Modules in this toolkit

**Core modules** (a client module with the same `Name` replaces it):

{{CoreModules}}

**Client modules already installed** (don't reuse these Names):

{{ClientModules}}

## Appendix B: Function names already used by core

Don't define functions with these names unless you are replacing the module they belong to:

{{CoreFunctions}}

---
*Generated by Client Setup for {{ProductName}} on {{Date}} (core v{{CoreVersion}}).*
