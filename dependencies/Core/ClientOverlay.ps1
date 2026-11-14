# Core: ClientOverlay.ps1
# Client overlay support: branding, client modules, client installers and versioning.
#
# A client repo is a copy of this core repo with one extra folder at the toolkit root:
#   client\branding.json   product name, accent color, logo, support contact, update feed
#   client\version.txt     the client's release version (drives self-update for client builds)
#   client\Modules\        client modules (same Register-<Name> contract as core modules)
#   client\CustomInstallers\
# See CLIENT_GUIDE.md. With no client\ folder, everything here returns the core defaults.
#
# Rules for this file (it runs on every launch, including ConnectWise Toolbox / SYSTEM runs):
#   - functions only, nothing executes at dot-source time
#   - no network, no extra assemblies, no prompts
#   - an overlay problem is recorded as a warning and the core default is used instead
#
# The functions below are the overlay API. Keep them backward compatible (see AGENTS.md).

function Get-ToolkitCoreDefaults {
    # Core branding. A plain core toolkit (no client\ folder) uses exactly these values.
    return @{
        ProductName     = 'Endpoint Toolkit'
        AccentColor     = '#89B4FA'
        Logo            = ''
        SupportContact  = ''
        UpdateBaseUrl   = 'https://github.com/abyssalsoldier/Endpoint-toolkit/releases/latest/download'
        DisabledModules = @()
        ExeName         = ''
    }
}

function Get-ToolkitContext {
    # The toolkit context hashtable: the shared SyncHash copy once the GUI is up
    # (main thread and runspaces), otherwise the orchestrator's $script:Toolkit.
    if ($Global:SyncHash -and $Global:SyncHash.Toolkit) { return $Global:SyncHash.Toolkit }
    if ($script:Toolkit) { return $script:Toolkit }
    return $null
}

function Get-ToolkitClientRoot {
    # <toolkit folder>\client, or $null when this is a plain core toolkit.
    param([string]$Parent)
    if (-not $Parent) {
        $ctx = Get-ToolkitContext
        if ($ctx) { $Parent = $ctx.Parent }
    }
    if (-not $Parent) { return $null }
    $clientRoot = Join-Path $Parent 'client'
    if (Test-Path -LiteralPath $clientRoot -PathType Container) { return $clientRoot }
    return $null
}

function Read-ToolkitVersionFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
    if (-not $text) { return $null }
    $text = $text.Trim()
    $parsed = $null
    if ([version]::TryParse($text, [ref]$parsed)) { return $text }
    return $null
}

function Get-ToolkitVersionInfo {
    # Core = dependencies\version.txt, Client = client\version.txt.
    # Effective is what the toolkit reports and what self-update compares: the client version when present.
    param(
        [Parameter(Mandatory)][string]$Root,     # dependencies\
        [Parameter(Mandatory)][string]$Parent    # toolkit folder
    )
    $core = Read-ToolkitVersionFile (Join-Path $Root 'version.txt')
    if (-not $core) { $core = '0.0.0' }
    $client = $null
    $clientRoot = Get-ToolkitClientRoot -Parent $Parent
    if ($clientRoot) { $client = Read-ToolkitVersionFile (Join-Path $clientRoot 'version.txt') }
    return @{
        Core      = $core
        Client    = $client
        Effective = if ($client) { $client } else { $core }
    }
}

function Get-ToolkitBranding {
    # Core defaults merged with client\branding.json. Unknown keys are ignored, invalid values
    # fall back to the default and add a message to -Warnings.
    param(
        [string]$Parent,
        [System.Collections.IList]$Warnings
    )
    $addWarning = { param($m) if ($null -ne $Warnings) { [void]$Warnings.Add($m) } }

    $branding = Get-ToolkitCoreDefaults
    $branding.IsClient = $false

    $clientRoot = Get-ToolkitClientRoot -Parent $Parent
    if (-not $clientRoot) { return $branding }

    $branding.IsClient = $true
    # A client build never falls back to the core release feed: updating a client USB from the core
    # feed would mirror away the client's folder. No valid client feed = no self-update.
    $branding.UpdateBaseUrl = ''

    $jsonPath = Join-Path $clientRoot 'branding.json'
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
        & $addWarning 'client\branding.json not found - using default branding, self-update disabled.'
        return $branding
    }

    try {
        $json = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        & $addWarning "client\branding.json could not be read ($($_.Exception.Message)) - using default branding, self-update disabled."
        return $branding
    }

    $get = { param($name) $p = $json.PSObject.Properties[$name]; if ($p) { $p.Value } else { $null } }

    $v = & $get 'ProductName'
    if ($v -is [string] -and $v.Trim()) { $branding.ProductName = $v.Trim() }

    $v = & $get 'AccentColor'
    if ($v) {
        if ($v -is [string] -and $v.Trim() -match '^#[0-9A-Fa-f]{6}$') { $branding.AccentColor = $v.Trim().ToUpper() }
        else { & $addWarning "branding.json AccentColor '$v' is not a #RRGGBB color - using the default." }
    }

    $v = & $get 'Logo'
    if ($v -is [string] -and $v.Trim()) { $branding.Logo = $v.Trim() }

    $v = & $get 'SupportContact'
    if ($v -is [string]) { $branding.SupportContact = $v.Trim() }

    $v = & $get 'UpdateBaseUrl'
    if ($v -is [string] -and $v.Trim() -match '^https://\S+$') { $branding.UpdateBaseUrl = $v.Trim().TrimEnd('/') }
    elseif ($v) { & $addWarning "branding.json UpdateBaseUrl '$v' is not an https URL - self-update disabled." }

    $v = & $get 'DisabledModules'
    if ($v) { $branding.DisabledModules = @($v | Where-Object { $_ -is [string] -and $_.Trim() } | ForEach-Object { $_.Trim() }) }

    $v = & $get 'ExeName'
    if ($v -is [string] -and $v.Trim()) {
        if ($v.Trim() -match '^[A-Za-z0-9._-]+$') { $branding.ExeName = $v.Trim() -replace '\.exe$', '' }
        else { & $addWarning "branding.json ExeName '$v' contains invalid characters - using the default exe name." }
    }

    return $branding
}

function Initialize-ToolkitOverlay {
    # Called once by Invoke-EndpointSetup.ps1 after Core is loaded. Fills in the context:
    # Version (effective), CoreVersion, ClientVersion, Branding, OverlayWarnings.
    $ctx = Get-ToolkitContext
    if (-not $ctx) { return }
    if (-not $ctx.OverlayWarnings) { $ctx.OverlayWarnings = [System.Collections.ArrayList]::new() }
    try {
        $v = Get-ToolkitVersionInfo -Root $ctx.Root -Parent $ctx.Parent
        $ctx.CoreVersion   = $v.Core
        $ctx.ClientVersion = $v.Client
        $ctx.Version       = $v.Effective
        $ctx.Branding      = Get-ToolkitBranding -Parent $ctx.Parent -Warnings $ctx.OverlayWarnings
    } catch {
        [void]$ctx.OverlayWarnings.Add("Client overlay failed to load ($($_.Exception.Message)) - using core defaults.")
        $ctx.Branding = Get-ToolkitCoreDefaults
        if (Get-ToolkitClientRoot -Parent $ctx.Parent) { $ctx.Branding.UpdateBaseUrl = '' }   # never the core feed on a client build
    }
}

function Get-ToolkitBrandingValue {
    param([Parameter(Mandatory)][string]$Name)
    $ctx = Get-ToolkitContext
    # Falls back to the core default only when branding was never loaded, so an intentionally
    # empty value (e.g. UpdateBaseUrl on a client build without a feed) stays empty.
    if ($ctx -and $ctx.Branding -and $ctx.Branding.ContainsKey($Name)) { return $ctx.Branding[$Name] }
    return (Get-ToolkitCoreDefaults)[$Name]
}

function Get-ToolkitProductName { Get-ToolkitBrandingValue 'ProductName' }

function Get-ToolkitAccent {
    # The branded accent color as '#RRGGBB'. Use this instead of hardcoding '#89B4FA'.
    $c = Get-ToolkitBrandingValue 'AccentColor'
    if ($c) { return $c }
    return '#89B4FA'
}

function New-ToolkitBrush {
    # SolidColorBrush from '#RRGGBB' (default: the branded accent).
    param([string]$Color)
    if (-not $Color) { $Color = Get-ToolkitAccent }
    return New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString($Color))
}

function Get-ToolkitLogoPath {
    # Full path of the client logo, resolved against the CURRENT toolkit folder (after a USB
    # launch that is the local temp copy). $null when there is no usable logo.
    $logo = Get-ToolkitBrandingValue 'Logo'
    if (-not $logo) { return $null }
    $clientRoot = Get-ToolkitClientRoot
    if (-not $clientRoot) { return $null }
    $full = [System.IO.Path]::GetFullPath((Join-Path $clientRoot $logo))
    if (-not $full.StartsWith($clientRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $full).Length -gt 256KB) { return $null }
    return $full
}

function Get-ToolkitModuleFiles {
    # Module .ps1 files to dot-source: core first, then client, so a client function with the
    # same name replaces the core one. Dot-source them in the CALLER's scope:
    #   Get-ToolkitModuleFiles | ForEach-Object { . $_.FullName }
    $ctx = Get-ToolkitContext
    if (-not $ctx) { return }
    foreach ($dir in (Get-ToolkitModulePaths)) {
        Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name
    }
}

function Get-ToolkitModulePaths {
    # Core Modules folder, plus client\Modules when it exists.
    $ctx = Get-ToolkitContext
    if (-not $ctx) { return @() }
    $paths = @(Join-Path $ctx.Root 'Modules')
    $clientRoot = Get-ToolkitClientRoot -Parent $ctx.Parent
    if ($clientRoot) {
        $clientModules = Join-Path $clientRoot 'Modules'
        if (Test-Path -LiteralPath $clientModules -PathType Container) { $paths += $clientModules }
    }
    return $paths
}

function Get-ToolkitInstallerPaths {
    # Core CustomInstallers folder, plus client\CustomInstallers when it exists.
    $ctx = Get-ToolkitContext
    if (-not $ctx) { return @() }
    $paths = @()
    $core = Join-Path $ctx.Root 'CustomInstallers'
    if (Test-Path -LiteralPath $core -PathType Container) { $paths += $core }
    $clientRoot = Get-ToolkitClientRoot -Parent $ctx.Parent
    if ($clientRoot) {
        $clientInst = Join-Path $clientRoot 'CustomInstallers'
        if (Test-Path -LiteralPath $clientInst -PathType Container) { $paths += $clientInst }
    }
    return $paths
}

function Get-ToolkitPayloadExcludes {
    # Repo-only items (docs for clients/agents, templates, tooling) that must never ship in a
    # zip, SFX or USB build. Returns full paths under -Root for robocopy /XD and /XF.
    # Keep in sync with the zip exclusions in .github/workflows/release.yml.
    param([Parameter(Mandatory)][string]$Root)
    return @{
        Dirs  = @('tools', 'client.example') | ForEach-Object { Join-Path $Root $_ }
        Files = @('AGENTS.md', 'CLAUDE.md', 'CLIENT_GUIDE.md') | ForEach-Object { Join-Path $Root $_ }
    }
}
