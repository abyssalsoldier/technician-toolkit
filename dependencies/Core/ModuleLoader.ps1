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
    return $registered | Sort-Object { $_.SortOrder }
}

function Invoke-RegisteredModule {
    param(
        [hashtable]$Module
    )

    if ($Module.RequiresAuth -and -not $script:Toolkit.Authenticated) {
        Write-Host "  $($Module.Label) requires authentication. Skipping." -ForegroundColor Yellow
        return
    }

    Write-SessionEvent -Name $Module.Name -Label $Module.Label -Action {
        & $Module.EntryPoint
    }
}
