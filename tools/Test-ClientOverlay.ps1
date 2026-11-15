<#
.SYNOPSIS
    Validates a client overlay (client\) and that no core file has been changed.

.DESCRIPTION
    Run before every commit or build in a client toolkit (humans, AI agents, CI). The Client Setup
    wizard runs the same checks (tools\OverlayValidation.ps1).
      - client\branding.json, client\version.txt
      - client\Modules\*.ps1 : parsed (never executed). Registration, EntryPoint/UIDefinition,
                               collisions with core, writes into core folders, load-time code
      - core integrity       : every file outside client\ must match dependencies\core-manifest.json
                               (works without git)
      - -CheckCore           : additionally compares with the upstream git branch and reports new
                               core commits (client repos that use GitHub)

    Exit code 0 = OK (warnings allowed), 1 = errors found.

.EXAMPLE
    .\tools\Test-ClientOverlay.ps1
    .\tools\Test-ClientOverlay.ps1 -CheckCore
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$CheckCore,
    [string]$Upstream = 'upstream/main',   # the core publishes from main (it was master before v2.2.1)
    [switch]$SkipIntegrity    # core maintainers / CI on the core repo only
)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Split-Path $PSScriptRoot -Parent }
$Path = (Resolve-Path $Path).Path
if (-not (Test-Path (Join-Path $Path 'dependencies/Invoke-EndpointSetup.ps1'))) { Write-Host "Not a toolkit folder: $Path" -ForegroundColor Red; exit 1 }

. (Join-Path $PSScriptRoot 'OverlayValidation.ps1')
. (Join-Path $Path 'dependencies/Agent/CoreIntegrity.ps1')

$errorCount = 0; $warnCount = 0
function Show-Result {
    param([string]$Title, [hashtable]$R)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    foreach ($m in $R.Infos)    { Write-Host "  [OK]    $m" -ForegroundColor Green }
    foreach ($m in $R.Warnings) { Write-Host "  [WARN]  $m" -ForegroundColor Yellow; $script:warnCount++ }
    foreach ($m in $R.Errors)   { Write-Host "  [ERROR] $m" -ForegroundColor Red;    $script:errorCount++ }
}

Write-Host "Client overlay check: $Path" -ForegroundColor Cyan

Show-Result 'Client overlay' (Test-OvClientOverlay -Root $Path)

# --- Core integrity (manifest, no git needed) ---
if (-not $SkipIntegrity) {
    $ci = Test-ToolkitCoreIntegrity -Root $Path
    $r = @{ Infos = @(); Warnings = @($ci.Warnings); Errors = @() }
    $isClient = Test-Path (Join-Path $Path 'client') -PathType Container
    if ($ci.NoManifest) { $r.Warnings += 'No dependencies\core-manifest.json - core integrity cannot be verified.' }
    elseif ($ci.Ok) { $r.Infos += "All core files match the shipped core v$($ci.CoreVersion)." }
    else {
        $lines = @(Format-ToolkitIntegrityReport -Result $ci)
        if ($isClient) { $r.Errors += $lines; $r.Errors += 'Restore the original core files and keep customizations in client\.' }
        else { $r.Warnings += $lines; $r.Warnings += 'Core checkout: run .\build.ps1 -UpdateCoreManifest before committing.' }
    }
    Show-Result 'Core integrity' $r
}

# --- Upstream comparison (git, optional) ---
if ($CheckCore) {
    $r = @{ Infos = @(); Warnings = @(); Errors = @() }
    Push-Location $Path
    try {
        git rev-parse --verify --quiet $Upstream *> $null
        if ($LASTEXITCODE -ne 0) {
            if ($Upstream -eq 'upstream/main' -and (git rev-parse --verify --quiet 'upstream/master' 2>$null)) {
                $r.Errors += "The core now publishes from 'main' (it was 'master'). Run: git fetch upstream --prune, then use git merge upstream/main"
            } else {
                $r.Errors += "Ref '$Upstream' not found. Run: git remote add upstream <core repo url>; git fetch upstream"
            }
        } else {
            $mergeBase = (git merge-base HEAD $Upstream).Trim()
            $changed = @(git -c core.safecrlf=false diff --name-only $mergeBase 2>$null) + @(git ls-files --others --exclude-standard 2>$null)
            $outside = @($changed | Where-Object { $_ -and $_ -notlike 'client/*' } | Sort-Object -Unique)
            if ($outside.Count -eq 0) { $r.Infos += "No files outside client\ differ from $Upstream." }
            else { foreach ($f in $outside) { $r.Errors += "Core file changed vs ${Upstream}: $f" } }
            $behind = (git rev-list --count "HEAD..$Upstream").Trim()
            if ([int]$behind -gt 0) { $r.Warnings += "$behind core commit(s) available. Update with: git merge $Upstream" }
        }
    } finally { Pop-Location }
    Show-Result "Upstream ($Upstream)" $r
}

Write-Host ""
if ($errorCount -gt 0) { Write-Host "FAILED: $errorCount error(s), $warnCount warning(s)." -ForegroundColor Red; exit 1 }
Write-Host "PASSED with $warnCount warning(s)." -ForegroundColor Green
exit 0
