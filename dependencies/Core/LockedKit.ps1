# Core: LockedKit.ps1
# Locked kits (locked exe, USB): the encrypted vault, unlock on demand, client secrets.
#
# A locked kit has client\.locked\vault.bin (built by dependencies\Agent\LockedPayload.ps1). The vault
# is encrypted with the kit's random main key and holds:
#   Secrets  : name -> value, entered on the wizard's Secrets page
#   Modules  : the full text of every locked client module (their .ps1 files are NOT in the kit)
#   Manifest : relative path -> SHA-256 of every kit file at build time (tamper check)
# The main key is only reachable with the password: .sfx-key (locked exe) or .toolkit-key (USB, also
# bound to the drive serial). Decrypted modules and secrets live in memory only, never on disk.
#
# Base folder (Launch.bat in a repo, no vault, no key files): everything is unlocked, and
# Get-ToolkitSecret reads the admin's own client\secrets.dat (Windows DPAPI) for testing.
#
# Function definitions only: this file is dot-sourced at every launch and in every runspace.

function Get-ToolkitSecretStorePath {
    param([Parameter(Mandatory)][string]$ClientRoot)
    Join-Path $ClientRoot 'secrets.dat'
}

function ConvertTo-ToolkitSecretTable {
    # JSON object -> ordered hashtable of string values
    param($Object)
    $table = [ordered]@{}
    if ($Object) { foreach ($p in $Object.PSObject.Properties) { $table[$p.Name] = [string]$p.Value } }
    return $table
}

function Read-ToolkitSecretStore {
    # The wizard's secrets for this Windows user (client\secrets.dat, DPAPI). Empty when there are none.
    # Throws when the file exists but belongs to another Windows user or PC.
    param([Parameter(Mandatory)][string]$ClientRoot)
    $path = Get-ToolkitSecretStorePath -ClientRoot $ClientRoot
    if (-not (Test-Path -LiteralPath $path)) { return [ordered]@{} }
    $bytes = Unprotect-ToolkitDpapi -Bytes ([System.IO.File]::ReadAllBytes($path))
    return ConvertTo-ToolkitSecretTable ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}

function Save-ToolkitSecretStore {
    param(
        [Parameter(Mandatory)][string]$ClientRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Secrets
    )
    $path = Get-ToolkitSecretStorePath -ClientRoot $ClientRoot
    if ($Secrets.Count -eq 0) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; return }
    $json = [pscustomobject]$Secrets | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllBytes($path, (Protect-ToolkitDpapi -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json))))
}

function Get-ToolkitVaultPath {
    param([string]$Parent)
    if (-not $Parent) { $ctx = Get-ToolkitContext; if ($ctx) { $Parent = $ctx.Parent } }
    if (-not $Parent) { return $null }
    Join-Path $Parent 'client\.locked\vault.bin'
}

function Get-ToolkitKitMode {
    # Base   : plain folder, everything unlocked
    # Locked : the password unlocks the kit (with or without a vault)
    param($Toolkit)
    if (-not $Toolkit) { $Toolkit = Get-ToolkitContext }
    $parent = $Toolkit.Parent
    if (Test-Path -LiteralPath (Get-ToolkitVaultPath -Parent $parent)) { return 'Locked' }
    if (Test-Path -LiteralPath (Join-Path $parent '.sfx-key')) { return 'Locked' }
    if ($Toolkit.IsUsb -and (Test-Path -LiteralPath (Join-Path $parent '.toolkit-key'))) { return 'Locked' }
    return 'Base'
}

function Get-ToolkitLockedIndex {
    # Menu placeholders for the encrypted modules: @{ Name; Label; SortOrder; Description }. No secrets.
    $ctx = Get-ToolkitContext
    if (-not $ctx) { return @() }
    $path = Join-Path $ctx.Parent 'client\.locked\index.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        # Assign first: in PS 5.1 ConvertFrom-Json emits a JSON array as ONE pipeline object
        $list = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return @(foreach ($m in @($list)) {
            @{ Name = [string]$m.Name; Label = [string]$m.Label; SortOrder = $m.SortOrder; Description = [string]$m.Description; RequiresAuth = $true; IsPlaceholder = $true }
        })
    } catch { return @() }
}

function Get-ToolkitMainKeyFromPassword {
    # The kit's main key for this password, or $null when the password is wrong / no key file exists.
    param([Parameter(Mandatory)][string]$Password)
    $ctx = Get-ToolkitContext
    $sfxKeyPath = Join-Path $ctx.Parent '.sfx-key'
    $usbKeyPath = Join-Path $ctx.Parent '.toolkit-key'
    try {
        if (Test-Path -LiteralPath $sfxKeyPath) {
            return Unprotect-SfxPassword -EncryptedData (Get-Content -LiteralPath $sfxKeyPath -Raw).Trim() -SfxPassword $Password
        }
        if ($ctx.IsUsb -and (Test-Path -LiteralPath $usbKeyPath)) {
            $serial = Get-ToolkitUsbSerial -Toolkit $ctx
            if (-not $serial) { return $null }
            return Unprotect-CachedPassword -EncryptedData (Get-Content -LiteralPath $usbKeyPath -Raw).Trim() -DriveSerial $serial -UserPassword $Password
        }
    } catch { }
    return $null
}

function Test-ToolkitKitIntegrity {
    # Compares the kit on disk with the vault's build-time manifest. Returns the changed paths (empty = OK).
    # Checked: every file under dependencies\ and client\. A core file may also match
    # dependencies\core-manifest.json, so a USB that self-updated its core still unlocks.
    # Not checked: CustomInstallers / Installers (technicians add installers there), client\Data,
    # client\_removed, client\.locked (the vault authenticates itself), and anything outside
    # dependencies\ and client\ (the technician's own files on the USB).
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][hashtable]$Manifest
    )
    . (Join-Path $Parent 'dependencies\Agent\CoreIntegrity.ps1')   # Get-ToolkitFileHash
    $core = @{}
    $coreManifestPath = Join-Path $Parent 'dependencies\core-manifest.json'
    if (Test-Path -LiteralPath $coreManifestPath) {
        try { (Get-Content -LiteralPath $coreManifestPath -Raw | ConvertFrom-Json).Files.PSObject.Properties | ForEach-Object { $core[$_.Name] = $_.Value } } catch { }
    }
    $root = (Resolve-Path -LiteralPath $Parent).Path.TrimEnd('\')
    $changed = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($top in 'dependencies', 'client') {
        $dir = Join-Path $root $top
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue) {
            $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
            if (Test-ToolkitIntegritySkip $rel) { continue }
            $seen[$rel] = $true
            $hash = Get-ToolkitFileHash $f.FullName
            $ok = ($Manifest.ContainsKey($rel) -and $Manifest[$rel] -eq $hash) -or
                  ($rel -like 'dependencies/*' -and $core.ContainsKey($rel) -and $core[$rel] -eq $hash)
            if (-not $ok) { $changed.Add($rel) }
        }
    }
    foreach ($rel in $Manifest.Keys) {
        if ($rel -like 'client/*' -and -not $seen.ContainsKey($rel) -and -not (Test-ToolkitIntegritySkip $rel)) { $changed.Add("$rel (missing)") }
    }
    return $changed.ToArray()   # callers wrap in @() (an empty result is an empty array)
}

function Test-ToolkitIntegritySkip {
    param([string]$RelativePath)
    $p = $RelativePath
    if ($p -match '(^|/)(CustomInstallers|Installers)(/|$)') { return $true }
    if ($p -match '^client/(Data|_removed|\.locked)(/|$)') { return $true }
    if ($p -eq 'dependencies/core-manifest.json') { return $true }
    return $false
}

function Unlock-ToolkitKit {
    # Checks the password, decrypts the vault, verifies the kit and keeps the locked modules and secrets
    # in memory. Returns @{ Ok; Message; Scripts } - Scripts are the decrypted module scriptblocks the
    # caller dot-sources (see Get-ToolkitModuleScripts). Never writes a decrypted byte to disk.
    param([Parameter(Mandatory)][string]$Password)
    $ctx = Get-ToolkitContext
    $mainKey = Get-ToolkitMainKeyFromPassword -Password $Password
    if (-not $mainKey) { return @{ Ok = $false; Message = 'Wrong password.' } }

    $vaultPath = Get-ToolkitVaultPath -Parent $ctx.Parent
    if (Test-Path -LiteralPath $vaultPath) {
        try {
            $plain = Unprotect-ToolkitBlob -Bytes ([System.IO.File]::ReadAllBytes($vaultPath)) -Key $mainKey
            $vault = [System.Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
        } catch {
            return @{ Ok = $false; Message = 'The locked part of this kit could not be opened (it was changed or belongs to another key). Rebuild the kit.' }
        }
        $manifest = @{}
        if ($vault.Manifest) { foreach ($p in $vault.Manifest.PSObject.Properties) { $manifest[$p.Name] = [string]$p.Value } }
        $changed = @(Test-ToolkitKitIntegrity -Parent $ctx.Parent -Manifest $manifest)
        if ($changed.Count -gt 0) {
            $list = ($changed | Select-Object -First 8) -join "`n"
            if ($changed.Count -gt 8) { $list += "`n... and $($changed.Count - 8) more" }
            return @{ Ok = $false; Message = "Kit files were changed, so the locked modules were not unlocked:`n`n$list`n`nRebuild the kit or re-create the USB." }
        }
        $ctx.Secrets = ConvertTo-ToolkitSecretTable $vault.Secrets
        $ctx.LockedModuleTexts = @(foreach ($m in @($vault.Modules)) { @{ RelPath = [string]$m.RelPath; Text = [string]$m.Text } })
    }

    $ctx.Authenticated = $true
    if ($Global:SyncHash) { $Global:SyncHash.ToolkitKey = $mainKey }
    $script:ToolkitKey = $mainKey
    return @{ Ok = $true; Message = 'Unlocked.' }
}

function Get-ToolkitSecret {
    # A secret from the wizard's Secrets page, or $null (kit still locked / name not defined).
    # Never log or display the value.
    param([Parameter(Mandatory)][string]$Name)
    $ctx = Get-ToolkitContext
    if (-not $ctx) { return $null }
    if ($null -eq $ctx.Secrets -and $ctx.KitMode -eq 'Base') {
        # Base folder on the admin's PC: read the DPAPI store once
        $ctx.Secrets = [ordered]@{}
        $clientRoot = Get-ToolkitClientRoot -Parent $ctx.Parent
        if ($clientRoot) {
            try { $ctx.Secrets = Read-ToolkitSecretStore -ClientRoot $clientRoot }
            catch { if ($ctx.OverlayWarnings) { [void]$ctx.OverlayWarnings.Add("client\secrets.dat could not be read by this Windows user: $($_.Exception.Message)") } }
        }
    }
    if ($ctx.Secrets -and $ctx.Secrets.Contains($Name)) { return $ctx.Secrets[$Name] }
    return $null
}
