# Agent: LockedPayload.ps1
# Turns a staged toolkit copy (locked exe staging folder, or a freshly copied USB) into a locked kit:
#   - every locked client module (RequiresAuth = $true, or listed in branding.json LockedModules) is
#     moved into the encrypted vault and its .ps1 file is deleted from the copy
#   - the wizard's secrets go into the vault
#   - the vault records a SHA-256 manifest of every kit file (tamper check at unlock)
#   - client\.locked\index.json (plain) lists the locked modules' Name/Label/SortOrder for the menu
# Runtime side: dependencies\Core\LockedKit.ps1. Not loaded at toolkit startup.
#
# Needs Crypto.ps1, ClientOverlay.ps1 (Core) dot-sourced by the caller; loads its other helpers itself.

. (Join-Path $PSScriptRoot 'ModuleMetadata.ps1')   # Read-OvModuleFile
. (Join-Path $PSScriptRoot 'CoreIntegrity.ps1')    # Get-ToolkitFileHash
. (Join-Path $PSScriptRoot '..\Core\LockedKit.ps1') # Test-ToolkitIntegritySkip, Read-ToolkitSecretStore

function Get-ToolkitLockedModuleInfo {
    # Locked client modules under <Root>\client\Modules: @{ File; Name; Label; SortOrder; Description }
    param([Parameter(Mandatory)][string]$Root)
    $clientModules = Join-Path $Root 'client\Modules'
    if (-not (Test-Path -LiteralPath $clientModules)) { return @() }
    $locked = @((Get-ToolkitBranding -Parent $Root).LockedModules)
    $result = @()
    foreach ($f in Get-ChildItem -LiteralPath $clientModules -Filter '*.ps1' -File | Sort-Object Name) {
        $p = Read-OvModuleFile $f.FullName
        $reg = $p.Registrations | Select-Object -First 1
        if (-not $reg -or -not $reg.Meta.Name) { continue }
        $m = $reg.Meta
        if ($m.RequiresAuth -eq $true -or $locked -contains '*' -or $locked -contains $m.Name) {
            $result += @{ File = $f.FullName; Name = [string]$m.Name; Label = [string]$m.Label; SortOrder = $m.SortOrder; Description = [string]$m.Description }
        }
    }
    return $result
}

function Get-ToolkitKitManifest {
    # relative path -> SHA-256 for every file Test-ToolkitKitIntegrity checks
    param([Parameter(Mandatory)][string]$Root)
    $Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $manifest = [ordered]@{}
    foreach ($top in 'dependencies', 'client') {
        $dir = Join-Path $Root $top
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName) {
            $rel = $f.FullName.Substring($Root.Length + 1).Replace('\', '/')
            if (Test-ToolkitIntegritySkip $rel) { continue }
            $manifest[$rel] = Get-ToolkitFileHash $f.FullName
        }
    }
    return $manifest
}

function New-ToolkitLockedPayload {
    # -Root    : the staged copy (it is changed in place)
    # -MainKey : from New-ToolkitMainKey; the caller wraps it with the password (.sfx-key / .toolkit-key)
    # -Secrets : name -> value (default: none)
    # Returns @{ LockedModules = <names>; SecretCount = <n> }
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$MainKey,
        [System.Collections.IDictionary]$Secrets = @{}
    )
    $Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $clientRoot = Join-Path $Root 'client'
    # Plain core kit: no client modules or secrets to protect. The password still gates RequiresAuth
    # core modules (.sfx-key / .toolkit-key), but those are public core code anyway.
    if (-not (Test-Path -LiteralPath $clientRoot -PathType Container)) { return @{ LockedModules = @(); SecretCount = 0 } }

    # The plain secret store must never ship
    foreach ($n in 'secrets.dat', 'secrets.pkg', 'secrets-names.json') {
        Remove-Item -LiteralPath (Join-Path $clientRoot $n) -Force -ErrorAction SilentlyContinue
    }

    $lockedDir = Join-Path $clientRoot '.locked'
    if (Test-Path -LiteralPath $lockedDir) { Remove-Item -LiteralPath $lockedDir -Recurse -Force }

    $locked = @(Get-ToolkitLockedModuleInfo -Root $Root)
    $modules = @()
    foreach ($m in $locked) {
        $modules += [ordered]@{
            RelPath = $m.File.Substring($Root.Length + 1).Replace('\', '/')
            # Same decoding as PowerShell uses for a .ps1: BOM if present, else the ANSI code page
            Text    = [System.IO.File]::ReadAllText($m.File, [System.Text.Encoding]::Default)
        }
        Remove-Item -LiteralPath $m.File -Force
    }

    New-Item -ItemType Directory -Path (Join-Path $clientRoot 'Modules') -Force | Out-Null
    New-Item -ItemType Directory -Path $lockedDir -Force | Out-Null

    $secretTable = [ordered]@{}
    foreach ($k in $Secrets.Keys) { $secretTable[[string]$k] = [string]$Secrets[$k] }

    $vault = [ordered]@{
        Format   = 1
        Created  = (Get-Date).ToUniversalTime().ToString('o')
        Secrets  = $secretTable
        Modules  = $modules
        Manifest = Get-ToolkitKitManifest -Root $Root      # after the locked files were removed
    }
    $json = $vault | ConvertTo-Json -Depth 6 -Compress
    $blob = Protect-ToolkitBlob -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json)) -Key $MainKey
    [System.IO.File]::WriteAllBytes((Join-Path $lockedDir 'vault.bin'), $blob)

    $index = @($locked | ForEach-Object { [ordered]@{ Name = $_.Name; Label = $_.Label; SortOrder = $_.SortOrder; Description = $_.Description } })
    $indexJson = if ($index.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $index -Depth 3 }
    [System.IO.File]::WriteAllText((Join-Path $lockedDir 'index.json'), $indexJson, (New-Object System.Text.UTF8Encoding $false))

    $json = $null; $secretTable = $null; $modules = $null
    return @{ LockedModules = @($locked | ForEach-Object { $_.Name }); SecretCount = $Secrets.Count }
}
