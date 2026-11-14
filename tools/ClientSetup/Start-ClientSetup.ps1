# tools/ClientSetup/Start-ClientSetup.ps1
# Client Setup wizard: create/edit the client\ overlay (brand, modules, installers, updates) and build.
# Started by Setup-Client.bat. Repo-only (never shipped in a toolkit build).
#
# Safety rules (see AGENTS.md):
#   - writes ONLY under client\ (every path goes through Get-ClientPath), plus _builds\ for build output
#     and backups, and a package path the user picks when exporting
#   - module files are validated by parsing (tools\OverlayValidation.ps1), never executed
#   - builds run build.ps1 / Export-LockedToolkit.ps1, which refuse when core files were changed

param([string]$Root)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
# The console is hidden (Setup-Client.bat), so startup failures must surface as a message box
trap { [System.Windows.MessageBox]::Show("Client Setup could not start:`n`n$($_.Exception.Message)", 'Client Setup', 'OK', 'Error') | Out-Null; break }

if (-not $Root) { $Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$Root = (Resolve-Path $Root).Path.TrimEnd('\')
$ClientRoot = Join-Path $Root 'client'
$BuildsRoot = Join-Path $Root '_builds'

. (Join-Path $Root 'dependencies\Core\ClientOverlay.ps1')
. (Join-Path $Root 'dependencies\Agent\CoreIntegrity.ps1')
. (Join-Path $Root 'tools\OverlayValidation.ps1')

# ---------------------------------------------------------------- helpers
function Show-Msg {
    param([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information')
    return [System.Windows.MessageBox]::Show($script:win, $Text, 'Client Setup', $Buttons, $Icon)
}

function Get-ClientPath {
    # Resolves a path and refuses anything outside client\ (the wizard's write boundary).
    param([Parameter(Mandatory)][string]$Relative)
    $base = [System.IO.Path]::GetFullPath($ClientRoot).TrimEnd('\')
    $full = [System.IO.Path]::GetFullPath((Join-Path $base $Relative))
    if ($full -ne $base -and -not $full.StartsWith("$base\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside the client folder: $full"
    }
    return $full
}

function Move-ToRemoved {
    # "Remove" = move into client\_removed\<timestamp>_<name> (undo by moving it back). Never shipped.
    param([Parameter(Mandatory)][string]$FullPath)
    $null = Get-ClientPath ($FullPath.Substring($ClientRoot.Length).TrimStart('\'))
    $bin = Get-ClientPath '_removed'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $target = Join-Path $bin ("{0}_{1}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), (Split-Path $FullPath -Leaf))
    Move-Item -LiteralPath $FullPath -Destination $target -Force
}

function New-Brush { param([string]$Hex) New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex)) }

function Format-Size { param([long]$Bytes) if ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) } else { '{0:N0} KB' -f [math]::Max(1, $Bytes / 1KB) } }

function Read-ClientVersion {
    $p = Join-Path $ClientRoot 'version.txt'
    if (Test-Path $p) { return (Get-Content $p -Raw).Trim() }
    return '1.0.0'
}

# ---------------------------------------------------------------- state
function Get-WizardState {
    $s = @{
        ProductName = ''; AccentColor = '#89B4FA'; Logo = ''; SupportContact = ''
        UpdateSource = 'core'; UpdateBaseUrl = ''; ExeName = ''
        Disabled = [System.Collections.Generic.HashSet[string]]::new()
        Locked = [System.Collections.Generic.HashSet[string]]::new()
        LockAll = $false
        Extra = [ordered]@{}           # unknown / _comment keys are preserved on save
        Version = Read-ClientVersion
        IsNew = -not (Test-Path (Join-Path $ClientRoot 'branding.json'))
    }
    if (-not $s.IsNew) {
        try { $j = Get-Content (Join-Path $ClientRoot 'branding.json') -Raw | ConvertFrom-Json }
        catch { Show-Msg "client\branding.json could not be read ($($_.Exception.Message)). Starting from defaults; saving will replace it." 'OK' 'Warning' | Out-Null; $j = $null }
        if ($j) {
            foreach ($p in $j.PSObject.Properties) {
                switch ($p.Name) {
                    'ProductName'     { $s.ProductName = "$($p.Value)" }
                    'AccentColor'     { if ("$($p.Value)" -match '^#[0-9A-Fa-f]{6}$') { $s.AccentColor = "$($p.Value)".ToUpper() } }
                    'Logo'            { $s.Logo = "$($p.Value)" }
                    'SupportContact'  { $s.SupportContact = "$($p.Value)" }
                    'UpdateSource'    { $s.UpdateSource = "$($p.Value)".ToLower() }
                    'UpdateBaseUrl'   { $s.UpdateBaseUrl = "$($p.Value)" }
                    'ExeName'         { $s.ExeName = "$($p.Value)" }
                    'DisabledModules' { foreach ($n in @($p.Value)) { if ($n) { [void]$s.Disabled.Add("$n") } } }
                    'LockedModules'   { foreach ($n in @($p.Value)) { if ($n -eq '*') { $s.LockAll = $true } elseif ($n) { [void]$s.Locked.Add("$n") } } }
                    default           { $s.Extra[$p.Name] = $p.Value }
                }
            }
            if (-not $j.PSObject.Properties['UpdateSource']) { $s.UpdateSource = if ($s.UpdateBaseUrl) { 'custom' } else { 'none' } }
        }
    }
    return $s
}

function Save-WizardState {
    # Reads the controls into $state and writes client\branding.json + client\version.txt.
    param([switch]$Quiet)
    $c = $script:ui
    $state.ProductName = $c.txtProductName.Text.Trim()
    $accent = $c.txtAccent.Text.Trim()
    if ($accent -match '^#[0-9A-Fa-f]{6}$') { $state.AccentColor = $accent.ToUpper() }
    $state.SupportContact = $c.txtSupport.Text.Trim()
    $v = $null
    if ([version]::TryParse($c.txtVersion.Text.Trim(), [ref]$v)) { $state.Version = $c.txtVersion.Text.Trim() }
    else { Show-Msg "'$($c.txtVersion.Text)' is not a version like 1.0.0 - keeping $($state.Version)." 'OK' 'Warning' | Out-Null; $c.txtVersion.Text = $state.Version }
    $state.UpdateSource = if ($c.rbCustom.IsChecked) { 'custom' } elseif ($c.rbNone.IsChecked) { 'none' } else { 'core' }
    $state.UpdateBaseUrl = $c.txtFeedUrl.Text.Trim()

    foreach ($d in 'Modules', 'CustomInstallers') { New-Item -ItemType Directory -Path (Get-ClientPath $d) -Force | Out-Null }

    $out = [ordered]@{}
    $out['_readme'] = 'Created by Setup-Client.bat (tools\ClientSetup). Edit with the wizard or by hand; see CLIENT_GUIDE.md.'
    $out.ProductName = $state.ProductName
    $out.AccentColor = $state.AccentColor
    $out.Logo = $state.Logo
    $out.SupportContact = $state.SupportContact
    $out.UpdateSource = $state.UpdateSource
    $out.UpdateBaseUrl = if ($state.UpdateSource -eq 'custom') { $state.UpdateBaseUrl } else { '' }
    $out.DisabledModules = @($state.Disabled | Sort-Object)
    $out.LockedModules = if ($state.LockAll) { @('*') } else { @($state.Locked | Sort-Object) }
    $out.ExeName = $state.ExeName
    foreach ($k in $state.Extra.Keys) { if ($k -ne '_readme') { $out[$k] = $state.Extra[$k] } }

    $json = $out | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Get-ClientPath 'branding.json'), $json, (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Get-ClientPath 'version.txt'), "$($state.Version)`r`n", (New-Object System.Text.UTF8Encoding $false))
    $state.IsNew = $false
    if (-not $Quiet) { Set-Status "Saved to client\ ($(Get-Date -Format 'HH:mm:ss'))." }
}

function Set-Status { param([string]$Text) $script:ui.txtStatus.Text = $Text }

# ---------------------------------------------------------------- window
$win = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlTextReader (Join-Path $PSScriptRoot 'ClientSetup.xaml')))
$ui = @{}
foreach ($n in 'txtCoreInfo', 'lstSteps', 'txtWelcome', 'bdrIntegrity', 'txtIntegrityTitle', 'txtIntegrityDetail', 'btnImport', 'btnOpenGuide',
               'imgPreviewLogo', 'txtPreviewName', 'txtPreviewVersion', 'txtProductName', 'txtAccent', 'pnlSwatches', 'btnLogo', 'btnLogoRemove', 'txtLogoInfo', 'txtSupport', 'txtVersion',
               'btnAddModule', 'btnLockAll', 'btnUnlockAll', 'txtNewModule', 'btnNewModule', 'pnlModules',
               'btnAddInstaller', 'txtInstallerTotal', 'pnlInstallers',
               'rbCore', 'rbCustom', 'rbNone', 'pnlCustom', 'txtFeedUrl', 'txtGitHubRepo', 'btnFillGitHub',
               'btnCheck', 'btnBuildExe', 'btnMakeUsb', 'btnExport', 'btnOpenBuilds', 'pwd1', 'pwd2', 'btnBuildLocked', 'txtOutput',
               'txtStatus', 'btnBack', 'btnNext', 'btnSave') {
    $ui[$n] = $win.FindName($n)
}
$pages = 0..5 | ForEach-Object { $win.FindName("page$_") }
$state = Get-WizardState

$coreVer = (Get-ToolkitVersionInfo -Root (Join-Path $Root 'dependencies') -Parent $Root).Core
$ui.txtCoreInfo.Text = "Core v$coreVer`n$Root"

# ---------------------------------------------------------------- navigation
function Show-Page {
    param([int]$Index)
    for ($i = 0; $i -lt $pages.Count; $i++) { $pages[$i].Visibility = if ($i -eq $Index) { 'Visible' } else { 'Collapsed' } }
    $ui.btnBack.IsEnabled = $Index -gt 0
    $ui.btnNext.Content = if ($Index -eq $pages.Count - 1) { 'Done' } else { 'Next' }
    switch ($Index) { 2 { Update-ModuleList } 3 { Update-InstallerList } }
    if ($ui.lstSteps.SelectedIndex -ne $Index) { $ui.lstSteps.SelectedIndex = $Index }
}
$ui.lstSteps.Add_SelectionChanged({ if ($ui.lstSteps.SelectedIndex -ge 0) { Show-Page $ui.lstSteps.SelectedIndex } })
$ui.btnBack.Add_Click({ if ($ui.lstSteps.SelectedIndex -gt 0) { $ui.lstSteps.SelectedIndex-- } })
$ui.btnNext.Add_Click({
    $i = $ui.lstSteps.SelectedIndex
    if ($i -ge 1) { Save-WizardState -Quiet }
    if ($i -lt $pages.Count - 1) { $ui.lstSteps.SelectedIndex = $i + 1 } else { Save-WizardState; $win.Close() }
})
$ui.btnSave.Add_Click({ Save-WizardState })

# ---------------------------------------------------------------- 1 welcome
function Update-Integrity {
    $r = Test-ToolkitCoreIntegrity -Root $Root
    if ($r.NoManifest) {
        $ui.bdrIntegrity.Background = New-Brush '#FF45403A'
        $ui.txtIntegrityTitle.Text = 'Core files could not be verified (no core-manifest.json).'
        $ui.txtIntegrityDetail.Text = 'Use a complete client kit from your toolkit provider.'
    } elseif ($r.Ok) {
        $ui.bdrIntegrity.Background = New-Brush '#FF2E4034'
        $ui.txtIntegrityTitle.Text = "Core v$($r.CoreVersion): all core files are original."
        $ui.txtIntegrityDetail.Text = (@($r.Warnings) -join "`n")
    } else {
        $ui.bdrIntegrity.Background = New-Brush '#FF45243D'
        $ui.txtIntegrityTitle.Text = 'Core files were changed - builds are blocked until they are restored.'
        $ui.txtIntegrityDetail.Text = ((@(Format-ToolkitIntegrityReport -Result $r) | Select-Object -First 8) -join "`n") + "`nRe-extract the client kit (keep your client folder) to restore them."
    }
    return $r
}
$ui.txtWelcome.Text = if ($state.IsNew) {
    'No client folder yet - this wizard creates one. Your name, colors, logo, modules and installers all live in the client folder; the core toolkit is never changed, so core updates can always be applied safely.'
} else {
    "Editing your existing client folder ($ClientRoot). The core toolkit is never changed by this wizard."
}
$ui.btnOpenGuide.Add_Click({ $g = Join-Path $Root 'CLIENT_GUIDE.md'; if (Test-Path $g) { Start-Process notepad.exe -ArgumentList "`"$g`"" } })

function Export-ClientPackage {
    param([Parameter(Mandatory)][string]$ZipPath)
    $stage = Join-Path $env:TEMP "client-package-$([guid]::NewGuid().ToString('N'))"
    try {
        robocopy $ClientRoot $stage /E /XD (Join-Path $ClientRoot '_removed') (Join-Path $ClientRoot 'Data') /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "copy failed (robocopy $LASTEXITCODE)" }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $ZipPath)
    } finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

$ui.btnImport.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Client package (*.zip)|*.zip'
    if (-not $dlg.ShowDialog($win)) { return }
    $tmp = Join-Path $env:TEMP "client-import-$([guid]::NewGuid().ToString('N'))"
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($dlg.FileName, $tmp)
        $src = if (Test-Path (Join-Path $tmp 'branding.json')) { $tmp } elseif (Test-Path (Join-Path $tmp 'client\branding.json')) { Join-Path $tmp 'client' } else { $null }
        if (-not $src) { Show-Msg 'This zip is not a client package (no branding.json found).' 'OK' 'Error' | Out-Null; return }
        if (Get-ChildItem $src -Recurse -File | Where-Object { $_.Name -like '*.key' -or $_.Name -in '.toolkit-key', '.sfx-key' }) { Show-Msg 'The package contains key files and was not imported.' 'OK' 'Error' | Out-Null; return }
        if ((Show-Msg "Import '$(Split-Path $dlg.FileName -Leaf)' as your client folder?$(if (Test-Path $ClientRoot) { "`n`nYour current client folder is backed up to _builds first." })" 'YesNo' 'Question') -ne 'Yes') { return }
        if (Test-Path $ClientRoot) {
            New-Item -ItemType Directory -Path $BuildsRoot -Force | Out-Null
            $backup = Join-Path $BuildsRoot "client-backup-$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
            Export-ClientPackage -ZipPath $backup
            Get-ChildItem $ClientRoot -Force | Where-Object { $_.Name -ne '_removed' } | ForEach-Object { $null = Get-ClientPath $_.Name; Remove-Item $_.FullName -Recurse -Force }
        }
        New-Item -ItemType Directory -Path $ClientRoot -Force | Out-Null
        robocopy $src $ClientRoot /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        $script:state = Get-WizardState
        Initialize-Controls
        Set-Status "Imported $(Split-Path $dlg.FileName -Leaf)$(if ($backup) { " (previous client folder backed up to $(Split-Path $backup -Leaf))" })."
    } catch { Show-Msg "Import failed: $($_.Exception.Message)" 'OK' 'Error' | Out-Null }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
})

# ---------------------------------------------------------------- 2 brand
function Update-Preview {
    $name = $ui.txtProductName.Text.Trim(); if (-not $name) { $name = 'Endpoint Toolkit' }
    $ui.txtPreviewName.Text = $name
    $hex = $ui.txtAccent.Text.Trim()
    if ($hex -match '^#[0-9A-Fa-f]{6}$') { $ui.txtPreviewName.Foreground = New-Brush $hex; $ui.txtAccent.BorderBrush = New-Brush '#FF4D4D6C' }
    else { $ui.txtAccent.BorderBrush = New-Brush '#FFF38BA8' }
    $ui.txtPreviewVersion.Text = "v$($ui.txtVersion.Text.Trim())"
    $logo = if ($state.Logo) { Join-Path $ClientRoot $state.Logo } else { $null }
    if ($logo -and (Test-Path $logo)) {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.UriSource = [Uri]$logo; $bmp.EndInit()
        $ui.imgPreviewLogo.Source = $bmp; $ui.imgPreviewLogo.Visibility = 'Visible'
        $ui.txtLogoInfo.Text = "client\$($state.Logo) ($(Format-Size (Get-Item $logo).Length))"
    } else {
        $ui.imgPreviewLogo.Visibility = 'Collapsed'; $ui.txtLogoInfo.Text = 'No logo'
    }
}
foreach ($hex in '#89B4FA', '#F38BA8', '#A6E3A1', '#FAB387', '#CBA6F7', '#94E2D5', '#F9E2AF', '#74C7EC') {
    $b = New-Object System.Windows.Controls.Button
    $b.Width = 24; $b.Height = 24; $b.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0); $b.Padding = [System.Windows.Thickness]::new(0)
    $b.Background = New-Brush $hex; $b.ToolTip = $hex; $b.Tag = $hex
    $b.Add_Click({ $ui.txtAccent.Text = $this.Tag })
    $ui.pnlSwatches.Children.Add($b) | Out-Null
}
$ui.txtProductName.Add_TextChanged({ Update-Preview })
$ui.txtAccent.Add_TextChanged({ Update-Preview })
$ui.txtVersion.Add_TextChanged({ Update-Preview })
$ui.btnLogo.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'PNG image (*.png)|*.png'
    if (-not $dlg.ShowDialog($win)) { return }
    $len = (Get-Item $dlg.FileName).Length
    if ($len -gt 256KB) { Show-Msg "That image is $(Format-Size $len). The limit is 256 KB - resize it (about 160 x 28 px is plenty)." 'OK' 'Warning' | Out-Null; return }
    New-Item -ItemType Directory -Path $ClientRoot -Force | Out-Null
    Copy-Item $dlg.FileName (Get-ClientPath 'logo.png') -Force
    $state.Logo = 'logo.png'
    Update-Preview; Save-WizardState
})
$ui.btnLogoRemove.Add_Click({
    if ($state.Logo -and (Test-Path (Join-Path $ClientRoot $state.Logo))) { Move-ToRemoved (Get-ClientPath $state.Logo) }
    $state.Logo = ''; Update-Preview; Save-WizardState
})

# ---------------------------------------------------------------- 3 modules
function Get-ClientModuleInfo {
    $list = @()
    foreach ($f in Get-ChildItem (Join-Path $ClientRoot 'Modules') -Filter '*.ps1' -File -ErrorAction SilentlyContinue) {
        $p = Read-OvModuleFile $f.FullName
        $reg = $p.Registrations | Select-Object -First 1
        $list += @{ File = $f.FullName; Name = if ($reg) { $reg.Meta.Name } else { $f.BaseName }; Label = if ($reg -and $reg.Meta.Label) { $reg.Meta.Label } else { $f.BaseName }; RequiresAuth = [bool]($reg -and $reg.Meta.RequiresAuth) }
    }
    return $list
}

function New-ModuleRow {
    param([string]$Label, [string]$Name, [string]$Source, [bool]$ForcedLock, [string]$RemoveFile)
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
    foreach ($w in '*', '130', '60', '60', '90') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::new([double]$w) }
        $g.ColumnDefinitions.Add($cd)
    }
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = "$Label"; $t.ToolTip = "Name: $Name"; $t.VerticalAlignment = 'Center'
    $s = New-Object System.Windows.Controls.TextBlock
    $s.Text = $Source; $s.VerticalAlignment = 'Center'; $s.Foreground = New-Brush $(if ($Source -eq 'Core') { '#FFA6ADC8' } else { '#FF89B4FA' })
    [System.Windows.Controls.Grid]::SetColumn($s, 1)

    $show = New-Object System.Windows.Controls.CheckBox
    $show.IsChecked = -not $state.Disabled.Contains($Name); $show.Tag = $Name; $show.VerticalAlignment = 'Center'
    $show.Add_Click({ if ($this.IsChecked) { [void]$state.Disabled.Remove($this.Tag) } else { [void]$state.Disabled.Add($this.Tag) }; Save-WizardState -Quiet })
    [System.Windows.Controls.Grid]::SetColumn($show, 2)

    $lock = New-Object System.Windows.Controls.CheckBox
    $lock.Tag = $Name; $lock.VerticalAlignment = 'Center'
    if ($ForcedLock) { $lock.IsChecked = $true; $lock.IsEnabled = $false; $lock.ToolTip = 'This module always requires the password.' }
    else {
        $lock.IsChecked = $state.LockAll -or $state.Locked.Contains($Name)
        $lock.Add_Click({
            if ($state.LockAll -and -not $this.IsChecked) {
                # leaving "lock all": keep every other module locked explicitly
                $state.LockAll = $false
                foreach ($n in $script:allModuleNames) { [void]$state.Locked.Add($n) }
            }
            if ($this.IsChecked) { [void]$state.Locked.Add($this.Tag) } else { [void]$state.Locked.Remove($this.Tag) }
            Save-WizardState -Quiet
        })
    }
    [System.Windows.Controls.Grid]::SetColumn($lock, 3)
    foreach ($el in $t, $s, $show, $lock) { $g.Children.Add($el) | Out-Null }

    if ($RemoveFile) {
        $rm = New-Object System.Windows.Controls.Button
        $rm.Content = 'Remove'; $rm.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2); $rm.Tag = @{ File = $RemoveFile; Label = $Label }
        $rm.Add_Click({
            if ((Show-Msg "Remove the module '$($this.Tag.Label)'?`n`nThe file is moved to client\_removed (not shipped) so you can restore it later." 'YesNo' 'Question') -ne 'Yes') { return }
            Move-ToRemoved $this.Tag.File
            Update-ModuleList; Set-Status "Removed $($this.Tag.Label)."
        })
        [System.Windows.Controls.Grid]::SetColumn($rm, 4)
        $g.Children.Add($rm) | Out-Null
    }
    return $g
}

function Update-ModuleList {
    $ui.pnlModules.Children.Clear()
    $script:coreInv = Get-OvCoreInventory -Root $Root
    $clientMods = @(Get-ClientModuleInfo)
    $replaced = @($clientMods | ForEach-Object { $_.Name })
    $script:allModuleNames = @($coreInv.Modules | ForEach-Object { $_.Name }) + $replaced | Select-Object -Unique
    foreach ($m in $coreInv.Modules) {
        if ($replaced -contains $m.Name) { continue }
        $ui.pnlModules.Children.Add((New-ModuleRow -Label $m.Label -Name $m.Name -Source 'Core' -ForcedLock $m.RequiresAuth)) | Out-Null
    }
    foreach ($m in $clientMods) {
        $src = if ($coreInv.Modules | Where-Object { $_.Name -eq $m.Name }) { 'Replaces core' } else { 'Client' }
        $ui.pnlModules.Children.Add((New-ModuleRow -Label $m.Label -Name $m.Name -Source $src -ForcedLock $m.RequiresAuth -RemoveFile $m.File)) | Out-Null
    }
}

function Add-ModuleFile {
    # Validates (parse only) and copies a module into client\Modules. Returns $true when added.
    param([Parameter(Mandatory)][string]$SourceFile, [string]$TargetName)
    if (-not $TargetName) { $TargetName = Split-Path $SourceFile -Leaf }
    $target = Get-ClientPath "Modules\$TargetName"
    $existing = @(Get-ClientModuleInfo | Where-Object { $_.File -ne $target } | ForEach-Object { $_.Name })
    $core = Get-OvCoreInventory -Root $Root
    $r = Test-OvClientModule -File $SourceFile -CoreInventory $core -OtherClientNames $existing
    if ($r.Errors.Count -gt 0) {
        Show-Msg ("This module can't be added:`n`n- " + ($r.Errors -join "`n- ")) 'OK' 'Error' | Out-Null
        return $false
    }
    $notes = @()
    if ($r.ReplacesCore) { $notes += "It REPLACES the core module '$($r.ReplacesCore)' (the core one is hidden while this module is installed)." }
    if ($r.Warnings.Count) { $notes += "Warnings:`n- " + ($r.Warnings -join "`n- ") }
    if (Test-Path $target) { $notes += "A module file named $TargetName already exists; it will be moved to client\_removed." }
    if ($notes.Count -and (Show-Msg ("Add '$($r.Meta.Label)'?`n`n" + ($notes -join "`n`n")) 'YesNo' 'Question') -ne 'Yes') { return $false }
    New-Item -ItemType Directory -Path (Get-ClientPath 'Modules') -Force | Out-Null
    if (Test-Path $target) { Move-ToRemoved $target }
    Copy-Item -LiteralPath $SourceFile -Destination $target -Force
    Set-Status "Added module $($r.Meta.Label)."
    return $true
}

$ui.btnAddModule.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'PowerShell module (*.ps1)|*.ps1'
    if (-not $dlg.ShowDialog($win)) { return }
    if ([System.IO.Path]::GetFullPath($dlg.FileName).StartsWith((Join-Path $Root 'dependencies'), [System.StringComparison]::OrdinalIgnoreCase)) {
        Show-Msg 'That is a core module. Core modules are already included - hide or lock them in the list instead.' 'OK' 'Information' | Out-Null; return
    }
    Save-WizardState -Quiet
    if (Add-ModuleFile -SourceFile $dlg.FileName) { Update-ModuleList }
})
$ui.btnNewModule.Add_Click({
    $label = $ui.txtNewModule.Text.Trim()
    $id = ($label -replace '[^A-Za-z0-9]', '')
    if (-not $id) { Show-Msg 'Type a name for the new module first (for example "Acme RMM").' | Out-Null; return }
    if ($id -match '^[0-9]') { $id = "M$id" }
    $template = Join-Path $Root 'client.example\Modules\Example-Module.ps1'
    if (-not (Test-Path $template)) { Show-Msg 'The module template (client.example\Modules\Example-Module.ps1) is missing from this kit.' 'OK' 'Error' | Out-Null; return }
    $text = (Get-Content $template -Raw).Replace('ClientExample', $id).Replace('Client Example', $label).Replace('Example-Module.ps1', "$id.ps1")
    $tmp = Join-Path $env:TEMP "$id.ps1"
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding $false))
    try {
        Save-WizardState -Quiet
        if (Add-ModuleFile -SourceFile $tmp -TargetName "$id.ps1") {
            Update-ModuleList; $ui.txtNewModule.Text = ''
            if ((Show-Msg "Created client\Modules\$id.ps1 from the template.`n`nOpen it in Notepad to write your module now?" 'YesNo' 'Question') -eq 'Yes') {
                Start-Process notepad.exe -ArgumentList "`"$(Get-ClientPath "Modules\$id.ps1")`""
            }
        }
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
})
$ui.btnLockAll.Add_Click({ $state.LockAll = $true; Save-WizardState -Quiet; Update-ModuleList })
$ui.btnUnlockAll.Add_Click({ $state.LockAll = $false; $state.Locked.Clear(); Save-WizardState -Quiet; Update-ModuleList })

# ---------------------------------------------------------------- 4 installers
function Update-InstallerList {
    $ui.pnlInstallers.Children.Clear()
    $dir = Join-Path $ClientRoot 'CustomInstallers'
    $files = @(Get-ChildItem $dir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.msi' })
    $total = ($files | Measure-Object Length -Sum).Sum
    $ui.txtInstallerTotal.Text = if ($files.Count) { "$($files.Count) installer(s), $(Format-Size $total) in total" } else { 'No installers yet.' }
    foreach ($f in $files) {
        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $rm = New-Object System.Windows.Controls.Button
        $rm.Content = 'Remove'; $rm.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2); $rm.Tag = $f.FullName
        [System.Windows.Controls.DockPanel]::SetDock($rm, 'Right')
        $rm.Add_Click({
            if ((Show-Msg "Remove $(Split-Path $this.Tag -Leaf)?`n`nIt is moved to client\_removed (not shipped)." 'YesNo' 'Question') -ne 'Yes') { return }
            Move-ToRemoved $this.Tag; Update-InstallerList
        })
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = "$($f.FullName.Substring($dir.Length + 1))    $(Format-Size $f.Length)"; $t.VerticalAlignment = 'Center'
        if ($f.Length -gt 25MB) { $t.Foreground = New-Brush '#FFF9E2AF'; $t.ToolTip = 'Large file - slows ConnectWise Toolbox uploads.' }
        $row.Children.Add($rm) | Out-Null; $row.Children.Add($t) | Out-Null
        $ui.pnlInstallers.Children.Add($row) | Out-Null
    }
}
$ui.btnAddInstaller.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Installers (*.exe;*.msi)|*.exe;*.msi'; $dlg.Multiselect = $true
    if (-not $dlg.ShowDialog($win)) { return }
    $dir = Get-ClientPath 'CustomInstallers'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($f in $dlg.FileNames) {
        $len = (Get-Item $f).Length
        if ($len -gt 25MB -and (Show-Msg "$(Split-Path $f -Leaf) is $(Format-Size $len). Large installers ship in every build and slow ConnectWise uploads. Add it anyway?" 'YesNo' 'Warning') -ne 'Yes') { continue }
        $target = Get-ClientPath "CustomInstallers\$(Split-Path $f -Leaf)"
        if (Test-Path $target) { Move-ToRemoved $target }
        Copy-Item -LiteralPath $f -Destination $target -Force
    }
    Update-InstallerList; Set-Status 'Installers updated.'
})

# ---------------------------------------------------------------- 5 updates
function Update-UpdateControls { $ui.pnlCustom.IsEnabled = [bool]$ui.rbCustom.IsChecked }
foreach ($rb in $ui.rbCore, $ui.rbCustom, $ui.rbNone) { $rb.Add_Checked({ Update-UpdateControls }) }
$ui.btnFillGitHub.Add_Click({
    $repo = $ui.txtGitHubRepo.Text.Trim().Trim('/') -replace '^https?://github\.com/', ''
    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') { Show-Msg 'Enter the repository as owner/name, for example acme-it/acme-toolkit.' | Out-Null; return }
    $ui.txtFeedUrl.Text = "https://github.com/$repo/releases/latest/download"
})

# ---------------------------------------------------------------- 6 check & build
function Write-Output2 { param([string]$Text) $ui.txtOutput.AppendText("$Text`r`n"); $ui.txtOutput.ScrollToEnd() }

function Invoke-FullCheck {
    # Saves, then runs every check. Returns $true when there are no errors.
    Save-WizardState -Quiet
    if ($ui.txtOutput.Text) { Write-Output2 '' }
    Write-Output2 "=== Check ($(Get-Date -Format 'HH:mm:ss')) ==="
    $ok = $true
    $r = Test-OvClientOverlay -Root $Root
    foreach ($m in $r.Infos)    { Write-Output2 "  OK     $m" }
    foreach ($m in $r.Warnings) { Write-Output2 "  WARN   $m" }
    foreach ($m in $r.Errors)   { Write-Output2 "  ERROR  $m"; $ok = $false }
    $ci = Update-Integrity
    if ($ci.Ok) { Write-Output2 "  OK     Core v$($ci.CoreVersion): all core files are original." }
    else { $ok = $false; foreach ($l in Format-ToolkitIntegrityReport -Result $ci) { Write-Output2 "  ERROR  $l" } }
    Write-Output2 ''
    Write-Output2 $(if ($ok) { 'All checks passed.' } else { 'Fix the errors above before building.' })
    Set-Status $(if ($ok) { 'All checks passed.' } else { 'Checks found problems - see the Check & Build page.' })
    return $ok
}

function Step-VersionIfRebuilt {
    # Raises the patch version when this version was already built, so devices see an update.
    $marker = Join-Path $BuildsRoot 'last-client-build.txt'
    if ((Test-Path $marker) -and (Get-Content $marker -Raw).Trim() -eq $state.Version) {
        $v = [version]$state.Version
        $patch = if ($v.Build -ge 0) { $v.Build + 1 } else { 1 }
        $ui.txtVersion.Text = "$($v.Major).$($v.Minor).$patch"
        Save-WizardState -Quiet
        Write-Output2 "Version raised to $($state.Version) (the previous build used $v)."
    }
}

$script:job = $null
function Start-BuildJob {
    # Runs a build script in a background runspace and streams the result into the output box.
    param([string]$Title, [string]$ScriptPath, [hashtable]$Params, [string]$SuccessNote)
    if ($script:job) { Show-Msg 'A build is already running.' | Out-Null; return }
    New-Item -ItemType Directory -Path $BuildsRoot -Force | Out-Null
    foreach ($b in 'btnBuildExe', 'btnBuildLocked', 'btnCheck') { $ui[$b].IsEnabled = $false }
    Write-Output2 "=== $Title ==="
    Set-Status "$Title..."
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($ScriptPath, $Params)
        # Load the built-in modules by full path: when started from a PowerShell 7 session, PSModulePath
        # points at PS7's copies first, which don't load in Windows PowerShell (e.g. Get-FileHash missing).
        foreach ($m in 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Security') {
            $psd1 = Join-Path $PSHOME "Modules\$m\$m.psd1"
            if (Test-Path $psd1) { Import-Module $psd1 -ErrorAction SilentlyContinue } else { Import-Module $m -ErrorAction SilentlyContinue }
        }
        $global:LASTEXITCODE = 0
        & $ScriptPath @Params *>&1 | ForEach-Object { "$_" }
        "__EXIT__$LASTEXITCODE"
    }).AddArgument($ScriptPath).AddArgument($Params)
    $script:job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Title = $Title; Note = $SuccessNote }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $timer.Add_Tick({
        if (-not $script:job.Handle.IsCompleted) { return }
        $this.Stop()
        $j = $script:job; $script:job = $null
        $exit = 1
        try {
            foreach ($line in $j.PS.EndInvoke($j.Handle)) {
                if ("$line" -match '^__EXIT__(\d*)$') { $exit = if ($matches[1]) { [int]$matches[1] } else { 0 } } else { Write-Output2 "$line" }
            }
            foreach ($e in $j.PS.Streams.Error) { Write-Output2 "ERROR: $e"; $exit = 1 }
        } catch { Write-Output2 "ERROR: $($_.Exception.Message)" }
        $j.PS.Dispose()
        foreach ($b in 'btnBuildExe', 'btnBuildLocked', 'btnCheck') { $ui[$b].IsEnabled = $true }
        if ($exit -eq 0) {
            Set-Content -Path (Join-Path $BuildsRoot 'last-client-build.txt') -Value $state.Version
            Write-Output2 "=== $($j.Title): done. $($j.Note) ==="
            Set-Status "$($j.Title) finished."
        } else {
            Write-Output2 "=== $($j.Title): FAILED (see above) ==="
            Set-Status "$($j.Title) failed."
        }
    })
    $timer.Start()
}

$ui.btnCheck.Add_Click({ Invoke-FullCheck | Out-Null })
$ui.btnBuildExe.Add_Click({
    if (-not (Invoke-FullCheck)) { return }
    Step-VersionIfRebuilt
    Start-BuildJob -Title 'Build exe' -ScriptPath (Join-Path $Root 'build.ps1') -Params @{ SFX = $true } -SuccessNote "Output: $BuildsRoot"
})
$ui.btnBuildLocked.Add_Click({
    if ($ui.pwd1.SecurePassword.Length -lt 4) { Show-Msg 'The password must be at least 4 characters.' 'OK' 'Warning' | Out-Null; return }
    $p1 = [System.Net.NetworkCredential]::new('', $ui.pwd1.SecurePassword).Password
    $p2 = [System.Net.NetworkCredential]::new('', $ui.pwd2.SecurePassword).Password
    $same = $p1 -ceq $p2; $p1 = $null; $p2 = $null
    if (-not $same) { Show-Msg 'The two passwords do not match.' 'OK' 'Warning' | Out-Null; return }
    if (-not (Invoke-FullCheck)) { return }
    Step-VersionIfRebuilt
    $secure = $ui.pwd1.SecurePassword.Copy()
    $ui.pwd1.Clear(); $ui.pwd2.Clear()
    Start-BuildJob -Title 'Build locked exe' -ScriptPath (Join-Path $Root 'dependencies\Agent\Export-LockedToolkit.ps1') -Params @{ Password = $secure; OutputPath = $BuildsRoot } -SuccessNote "Output: $BuildsRoot"
})
$ui.btnMakeUsb.Add_Click({
    if (-not (Invoke-FullCheck)) { return }
    if ((Show-Msg "The toolkit will open (Windows asks for administrator rights).`n`nInsert a USB stick (16 GB or more), then click 'USB Toolkit' in the toolkit's left menu and follow the steps. The stick gets your branding and modules." 'OKCancel' 'Information') -ne 'OK') { return }
    Start-Process -FilePath (Join-Path $Root 'Launch.bat') -WorkingDirectory $Root
})
$ui.btnExport.Add_Click({
    Save-WizardState -Quiet
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $safe = ($state.ProductName -replace '[^A-Za-z0-9]+', '-').Trim('-'); if (-not $safe) { $safe = 'client' }
    $dlg.FileName = "$safe-client-v$($state.Version).zip"; $dlg.Filter = 'Client package (*.zip)|*.zip'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if (-not $dlg.ShowDialog($win)) { return }
    $full = [System.IO.Path]::GetFullPath($dlg.FileName)
    if ($full.StartsWith($ClientRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith((Join-Path $Root 'dependencies'), [System.StringComparison]::OrdinalIgnoreCase)) {
        Show-Msg 'Save the package outside the toolkit folder (for example in Documents).' 'OK' 'Warning' | Out-Null; return
    }
    try { Export-ClientPackage -ZipPath $full; Write-Output2 "Client package saved: $full"; Set-Status 'Client package exported.' }
    catch { Show-Msg "Export failed: $($_.Exception.Message)" 'OK' 'Error' | Out-Null }
})
$ui.btnOpenBuilds.Add_Click({ New-Item -ItemType Directory -Path $BuildsRoot -Force | Out-Null; Start-Process explorer.exe -ArgumentList "`"$BuildsRoot`"" })

# ---------------------------------------------------------------- init
function Initialize-Controls {
    $ui.txtProductName.Text = $state.ProductName
    $ui.txtAccent.Text = $state.AccentColor
    $ui.txtSupport.Text = $state.SupportContact
    $ui.txtVersion.Text = $state.Version
    $ui.txtFeedUrl.Text = $state.UpdateBaseUrl
    switch ($state.UpdateSource) { 'custom' { $ui.rbCustom.IsChecked = $true } 'none' { $ui.rbNone.IsChecked = $true } default { $ui.rbCore.IsChecked = $true } }
    Update-UpdateControls
    Update-Preview
    $ui.txtWelcome.Text = if ($state.IsNew) { $ui.txtWelcome.Text } else { "Editing your existing client folder ($ClientRoot). The core toolkit is never changed by this wizard." }
}
Initialize-Controls
$null = Update-Integrity
$ui.lstSteps.SelectedIndex = 0
Show-Page 0
if ($state.IsNew) { Set-Status 'New client - nothing is written until you click Next or Save.' } else { Set-Status "Loaded client\ (v$($state.Version))." }

$win.ShowDialog() | Out-Null
