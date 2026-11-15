# Core: ModuleLoader.ps1
# Discovers and registers toolkit modules via convention-based Register-* functions
#
# Module files must be dot-sourced by the caller BEFORE calling Get-RegisteredModules.
# This ensures functions like Start-SoftwareInstall persist in the caller's scope:
#   Get-ToolkitModuleFiles | ForEach-Object { . $_.FullName }
#
# Modules come from dependencies\Modules (core) and client\Modules (client overlay, see
# ClientOverlay.ps1). A client module whose Name matches a core module replaces it, and
# modules named in branding.json DisabledModules are left out of the menu.

function Get-RegisteredModules {
    $modulePaths = @(Get-ToolkitModulePaths)
    $clientRoot  = Get-ToolkitClientRoot
    $disabled    = @(Get-ToolkitBrandingValue 'DisabledModules')

    $byName = [ordered]@{}

    # Find all Register-* functions currently in scope
    $registerFunctions = Get-Command -Name "Register-*" -CommandType Function -ErrorAction SilentlyContinue

    foreach ($fn in $registerFunctions) {
        # Only call functions defined in a Modules directory (core or client)
        $source = $fn.ScriptBlock.File
        if (-not $source) { continue }
        $inModules = $false
        foreach ($p in $modulePaths) {
            if ($source -like "$p\*") { $inModules = $true; break }
        }
        if (-not $inModules) { continue }

        try {
            $meta = & $fn.Name
            if ($meta -and $meta.Name -and $meta.EntryPoint) {
                $isClient = [bool]($clientRoot -and $source -like "$clientRoot\*")
                $meta.IsClient = $isClient
                if ($byName.Contains($meta.Name) -and -not $isClient) { continue }   # client wins
                $byName[$meta.Name] = $meta
            }
        } catch {
            Write-Host "WARNING: Failed to register $($fn.Name): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $registered = @($byName.Values | Where-Object { $disabled -notcontains $_.Name })

    # MinCoreVersion: a module built for a newer core is skipped (logged), never forcing a core patch
    $ctx = Get-ToolkitContext
    $coreVersion = $null
    if ($ctx -and $ctx.CoreVersion) { [void][version]::TryParse($ctx.CoreVersion, [ref]$coreVersion) }
    if ($coreVersion) {
        $registered = @($registered | Where-Object {
            $need = $null
            if ($_.MinCoreVersion -and [version]::TryParse([string]$_.MinCoreVersion, [ref]$need) -and $need -gt $coreVersion) {
                if ($null -ne $ctx.OverlayWarnings) { [void]$ctx.OverlayWarnings.Add("Module '$($_.Label)' needs core v$need or later (this is v$coreVersion) - skipped.") }
                $false
            } else { $true }
        })
    }

    # LockedModules (branding.json): a client can add locks, never remove one a module sets itself
    $locked = @(Get-ToolkitBrandingValue 'LockedModules')
    if ($locked.Count -gt 0) {
        foreach ($m in $registered) {
            if ($locked -contains '*' -or $locked -contains $m.Name) { $m.RequiresAuth = $true }
        }
    }

    return $registered | Sort-Object { $_.SortOrder }
}
