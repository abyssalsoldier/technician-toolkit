<#
.SYNOPSIS
    Validates a client overlay (client\) and, optionally, that no core file has been edited.

.DESCRIPTION
    Run before every commit in a client repo (humans and AI agents), and in CI.
      - client\branding.json : parses, known keys, valid values, logo present and small
      - client\version.txt   : present and a valid version
      - client\Modules\*.ps1 : parse cleanly, do no work at load time, Register-* returns the
                               required keys, EntryPoint/UIDefinition functions exist
      - collisions with core modules/functions are reported (overrides are allowed but should be intentional)
      - -CheckCore           : fails if any file OUTSIDE client\ differs from the upstream core

    Exit code 0 = OK (warnings allowed), 1 = errors found.

.PARAMETER Path
    Toolkit repo root. Defaults to the parent of this script's folder.

.PARAMETER CheckCore
    Compare against the upstream core (git) and fail on any change outside client\.

.PARAMETER Upstream
    The upstream ref to compare with. Default: upstream/master.

.EXAMPLE
    .\tools\Test-ClientOverlay.ps1 -CheckCore
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$CheckCore,
    [string]$Upstream = 'upstream/master'
)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Split-Path $PSScriptRoot -Parent }
$Path = (Resolve-Path $Path).Path

$errors   = [System.Collections.ArrayList]::new()
$warnings = [System.Collections.ArrayList]::new()
function Add-Err  { param($m) [void]$errors.Add($m);   Write-Host "  [ERROR] $m" -ForegroundColor Red }
function Add-Warn { param($m) [void]$warnings.Add($m); Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function Add-Ok   { param($m) Write-Host "  [OK]    $m" -ForegroundColor Green }

$depsRoot   = Join-Path $Path 'dependencies'
$clientRoot = Join-Path $Path 'client'
$coreModulesDir = Join-Path $depsRoot 'Modules'
if (-not (Test-Path (Join-Path $depsRoot 'Invoke-EndpointSetup.ps1'))) {
    Write-Host "Not a toolkit repo: $Path" -ForegroundColor Red
    exit 1
}

# --- AST helpers (core modules are parsed, never executed) ---
function Get-ScriptAst {
    param([string]$File)
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$parseErrors)
    return @{ Ast = $ast; Errors = $parseErrors }
}

function Get-DefinedFunctionNames {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name })
}

function Get-RegisteredNamesFromAst {
    # Module 'Name' values from Register-* hashtables, without running the file
    param($Ast)
    $names = @()
    $regs = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Register-*' }, $true)
    foreach ($r in $regs) {
        $ht = $r.Body.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        if (-not $ht) { continue }
        foreach ($pair in $ht.KeyValuePairs) {
            if ($pair.Item1.Extent.Text.Trim("'`"") -eq 'Name') {
                $names += $pair.Item2.Extent.Text.Trim().Trim("'`"")
            }
        }
    }
    return $names
}

# --- Core inventory ---
$coreFunctions   = @{}
$coreModuleNames = @()
foreach ($f in Get-ChildItem $coreModulesDir -Filter '*.ps1' -File) {
    $p = Get-ScriptAst $f.FullName
    foreach ($fn in Get-DefinedFunctionNames $p.Ast) { $coreFunctions[$fn] = $f.Name }
    $coreModuleNames += Get-RegisteredNamesFromAst $p.Ast
}

Write-Host ""
Write-Host "Client overlay check: $Path" -ForegroundColor Cyan

if (-not (Test-Path $clientRoot -PathType Container)) {
    Write-Host "  No client\ folder - this is a core-only checkout." -ForegroundColor Gray
} else {
    # --- branding.json ---
    Write-Host ""
    Write-Host "branding.json" -ForegroundColor Cyan
    $brandingPath = Join-Path $clientRoot 'branding.json'
    $branding = $null
    if (-not (Test-Path $brandingPath)) {
        Add-Err 'client\branding.json is missing (copy it from client.example\).'
    } else {
        try { $branding = Get-Content $brandingPath -Raw | ConvertFrom-Json } catch { Add-Err "client\branding.json is not valid JSON: $($_.Exception.Message)" }
    }
    if ($branding) {
        $known = 'ProductName', 'AccentColor', 'Logo', 'SupportContact', 'UpdateBaseUrl', 'DisabledModules', 'ExeName'
        foreach ($prop in $branding.PSObject.Properties.Name) {
            if ($known -notcontains $prop -and $prop -notlike '_*') { Add-Warn "Unknown key '$prop' (ignored by the toolkit). Known: $($known -join ', ')" }
        }
        if ($branding.ProductName) { Add-Ok "ProductName: $($branding.ProductName)" } else { Add-Warn 'ProductName not set - the core name will be shown.' }

        if ($branding.AccentColor) {
            if ($branding.AccentColor -match '^#[0-9A-Fa-f]{6}$') { Add-Ok "AccentColor: $($branding.AccentColor)" }
            else { Add-Err "AccentColor '$($branding.AccentColor)' must be #RRGGBB." }
        }

        if ($branding.UpdateBaseUrl) {
            if ($branding.UpdateBaseUrl -notmatch '^https://\S+$') { Add-Err "UpdateBaseUrl must be an https URL." }
            elseif ($branding.UpdateBaseUrl -match 'abyssalsoldier/Endpoint-toolkit') { Add-Err 'UpdateBaseUrl points at the CORE release feed. A client must use its own repo''s feed, or USB updates would remove client\.' }
            else {
                Add-Ok "UpdateBaseUrl: $($branding.UpdateBaseUrl)"
                if ($branding.UpdateBaseUrl -notmatch '/releases/latest/download/?$') { Add-Warn 'UpdateBaseUrl usually ends with /releases/latest/download (GitHub Releases).' }
            }
        } else {
            Add-Warn 'UpdateBaseUrl not set - USB toolkits will not self-update.'
        }

        if ($branding.Logo) {
            $logo = [System.IO.Path]::GetFullPath((Join-Path $clientRoot $branding.Logo))
            if (-not $logo.StartsWith($clientRoot, [System.StringComparison]::OrdinalIgnoreCase)) { Add-Err 'Logo must be a path inside client\.' }
            elseif (-not (Test-Path $logo -PathType Leaf)) { Add-Err "Logo file not found: client\$($branding.Logo)" }
            elseif ((Get-Item $logo).Length -gt 256KB) { Add-Err "Logo is $([math]::Round((Get-Item $logo).Length / 1KB)) KB; the limit is 256 KB (it would not be shown)." }
            elseif ($logo -notmatch '\.(png|jpg|jpeg|ico|bmp)$') { Add-Warn 'Logo should be a PNG.' }
            else { Add-Ok "Logo: client\$($branding.Logo)" }
        }

        if ($branding.ExeName -and $branding.ExeName -notmatch '^[A-Za-z0-9._-]+$') { Add-Err "ExeName '$($branding.ExeName)' may only contain letters, digits, '.', '_' and '-'." }
        elseif ($branding.ExeName) { Add-Warn "ExeName '$($branding.ExeName)' renames the exe - update any ConnectWise Toolbox entries that run the old name." }
    }

    # --- version.txt ---
    Write-Host ""
    Write-Host "version.txt" -ForegroundColor Cyan
    $verPath = Join-Path $clientRoot 'version.txt'
    $v = $null
    if (-not (Test-Path $verPath)) { Add-Err 'client\version.txt is missing (it drives client releases and USB self-update).' }
    elseif (-not [version]::TryParse((Get-Content $verPath -Raw).Trim(), [ref]$v)) { Add-Err "client\version.txt '$((Get-Content $verPath -Raw).Trim())' is not a version like 1.0.0." }
    else { Add-Ok "Client version: $v" }

    # --- Modules ---
    Write-Host ""
    Write-Host "Modules" -ForegroundColor Cyan
    $clientModulesDir = Join-Path $clientRoot 'Modules'
    $clientModuleNames = @()
    $clientFiles = @(if (Test-Path $clientModulesDir) { Get-ChildItem $clientModulesDir -Filter '*.ps1' -File })
    if ($clientFiles.Count -eq 0) { Write-Host '  No client modules.' -ForegroundColor Gray }

    foreach ($file in $clientFiles) {
        $label = "Modules\$($file.Name)"
        $p = Get-ScriptAst $file.FullName
        if ($p.Errors.Count -gt 0) {
            foreach ($e in $p.Errors) { Add-Err "${label}: line $($e.Extent.StartLineNumber): $($e.Message)" }
            continue
        }

        # Work at load time slows every launch (and every runspace) - only functions and simple assignments allowed
        foreach ($stmt in $p.Ast.EndBlock.Statements) {
            $isFunction = $stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]
            $isSimpleAssign = $stmt -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                -not $stmt.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            if (-not $isFunction -and -not $isSimpleAssign) {
                Add-Warn "${label}: line $($stmt.Extent.StartLineNumber) runs code at load time. Modules are loaded on every launch and in every background task - move work into functions."
            }
        }

        # Function collisions with core
        foreach ($fn in Get-DefinedFunctionNames $p.Ast) {
            if ($coreFunctions.ContainsKey($fn)) { Add-Warn "${label}: function $fn replaces the core function in $($coreFunctions[$fn]). Make sure this is intentional." }
        }

        # Register-* contract (dot-source in an isolated child scope)
        $result = & {
            param($moduleFile)
            . $moduleFile
            $regs = @(Get-Command -Name 'Register-*' -CommandType Function | Where-Object { $_.ScriptBlock.File -eq $moduleFile })
            $out = @()
            foreach ($r in $regs) {
                $meta = $null; $err = $null
                try { $meta = & $r.Name } catch { $err = $_.Exception.Message }
                $out += @{
                    Fn = $r.Name; Meta = $meta; Err = $err
                    EntryExists = [bool]($meta -and $meta.EntryPoint -and (Get-Command $meta.EntryPoint -CommandType Function -ErrorAction SilentlyContinue))
                    UIExists    = [bool]($meta -and $meta.UIDefinition -and (Get-Command $meta.UIDefinition -CommandType Function -ErrorAction SilentlyContinue))
                }
            }
            , $out
        } $file.FullName

        if ($result.Count -eq 0) { Add-Err "${label}: no Register-<Name> function found - the module will not appear in the menu."; continue }
        foreach ($r in $result) {
            if ($r.Err) { Add-Err "${label}: $($r.Fn) threw: $($r.Err)"; continue }
            $m = $r.Meta
            if (-not ($m -is [hashtable])) { Add-Err "${label}: $($r.Fn) must return a hashtable."; continue }
            $ok = $true
            foreach ($key in 'Name', 'Label', 'EntryPoint', 'SortOrder') {
                if (-not $m.ContainsKey($key) -or $null -eq $m[$key] -or "$($m[$key])" -eq '') { Add-Err "${label}: $($r.Fn) is missing '$key'."; $ok = $false }
            }
            if ($m.SortOrder -and -not ($m.SortOrder -is [int] -or $m.SortOrder -is [double])) { Add-Err "${label}: SortOrder must be a number."; $ok = $false }
            if ($m.EntryPoint -and -not $r.EntryExists) { Add-Err "${label}: EntryPoint '$($m.EntryPoint)' is not defined in the module."; $ok = $false }
            if ($m.UIDefinition -and -not $r.UIExists) { Add-Err "${label}: UIDefinition '$($m.UIDefinition)' is not defined in the module."; $ok = $false }
            if ($m.Name) {
                $clientModuleNames += $m.Name
                if ($coreModuleNames -contains $m.Name) { Add-Warn "${label}: Name '$($m.Name)' matches a core module - the client module REPLACES it in the menu." }
            }
            if ($ok) { Add-Ok "$label -> $($m.Name) ('$($m.Label)', SortOrder $($m.SortOrder))" }
        }
    }

    if ($branding -and $branding.DisabledModules) {
        foreach ($d in @($branding.DisabledModules)) {
            if (($coreModuleNames + $clientModuleNames) -notcontains $d) { Add-Warn "DisabledModules: '$d' does not match any module Name. Known core modules: $($coreModuleNames -join ', ')" }
            else { Add-Ok "Disabled: $d" }
        }
    }

    # --- Payload size / secrets ---
    Write-Host ""
    Write-Host "Payload" -ForegroundColor Cyan
    $allClient = @(Get-ChildItem $clientRoot -Recurse -File -Force)
    $totalMB = [math]::Round((($allClient | Measure-Object Length -Sum).Sum) / 1MB, 2)
    Add-Ok "client\ is $totalMB MB in $($allClient.Count) files (it ships in every zip, SFX and USB)."
    foreach ($big in $allClient | Where-Object { $_.Length -gt 25MB }) {
        Add-Warn "Large file client\$($big.FullName.Substring($clientRoot.Length + 1)) ($([math]::Round($big.Length / 1MB)) MB) - ConnectWise Toolbox uploads get slower."
    }
    foreach ($secret in $allClient | Where-Object { $_.Name -like '*.key' -or $_.Name -in '.toolkit-key', '.sfx-key' }) {
        Add-Err "Key file must not be committed: client\$($secret.FullName.Substring($clientRoot.Length + 1))"
    }
}

# --- Core integrity (client repos) ---
if ($CheckCore) {
    Write-Host ""
    Write-Host "Core integrity vs $Upstream" -ForegroundColor Cyan
    Push-Location $Path
    try {
        git rev-parse --verify --quiet $Upstream *> $null
        if ($LASTEXITCODE -ne 0) {
            Add-Err "Ref '$Upstream' not found. Run: git remote add upstream <core repo url>; git fetch upstream"
        } else {
            $mergeBase = (git merge-base HEAD $Upstream).Trim()
            # Tracked changes (committed + uncommitted) since the last core merge, plus untracked files
            $changed = @(git -c core.safecrlf=false diff --name-only $mergeBase 2>$null) + @(git ls-files --others --exclude-standard 2>$null)
            $outside = @($changed | Where-Object { $_ -and $_ -notlike 'client/*' } | Sort-Object -Unique)
            if ($outside.Count -eq 0) {
                Add-Ok 'No core files changed - all customization is inside client\.'
            } else {
                foreach ($f in $outside) { Add-Err "Core file changed: $f (revert it, or propose the change to the core repo)" }
            }
            $behind = (git rev-list --count "HEAD..$Upstream").Trim()
            if ([int]$behind -gt 0) { Add-Warn "$behind core commit(s) available. Update with: git merge $Upstream" }
        }
    } finally { Pop-Location }
}

Write-Host ""
if ($errors.Count -gt 0) {
    Write-Host "FAILED: $($errors.Count) error(s), $($warnings.Count) warning(s)." -ForegroundColor Red
    exit 1
}
Write-Host "PASSED with $($warnings.Count) warning(s)." -ForegroundColor Green
exit 0
