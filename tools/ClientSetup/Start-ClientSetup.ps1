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
. (Join-Path $Root 'dependencies\Core\Crypto.ps1')      # DPAPI + passphrase blobs (Secrets page, client package)
. (Join-Path $Root 'dependencies\Core\LockedKit.ps1')   # Read/Save-ToolkitSecretStore
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
    # @(...) around the whole expression: an if/else returning an empty array would collapse to $null
    $out.DisabledModules = @($state.Disabled | Sort-Object)
    $out.LockedModules = @(if ($state.LockAll) { '*' } else { $state.Locked | Sort-Object })
    $out.ExeName = $state.ExeName
    foreach ($k in $state.Extra.Keys) { if ($k -ne '_readme') { $out[$k] = $state.Extra[$k] } }

    $json = $out | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Get-ClientPath 'branding.json'), $json, (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Get-ClientPath 'version.txt'), "$($state.Version)`r`n", (New-Object System.Text.UTF8Encoding $false))
    $state.IsNew = $false
    Save-WizardSecrets
    if (-not $Quiet) { Set-Status "Saved to client\ ($(Get-Date -Format 'HH:mm:ss'))." }
}

function Set-Status { param([string]$Text) $script:ui.txtStatus.Text = $Text }

# ---------------------------------------------------------------- window
$win = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlTextReader (Join-Path $PSScriptRoot 'ClientSetup.xaml')))
$ui = @{}
foreach ($n in 'txtCoreInfo', 'lstSteps', 'txtWelcome', 'bdrIntegrity', 'txtIntegrityTitle', 'txtIntegrityDetail', 'btnImport', 'btnOpenGuide',
               'imgPreviewLogo', 'txtPreviewName', 'txtPreviewVersion', 'txtProductName', 'txtAccent', 'pnlSwatches', 'btnLogo', 'btnLogoRemove', 'txtLogoInfo', 'txtSupport', 'txtVersion',
               'btnAddModule', 'btnLockAll', 'btnUnlockAll', 'btnModuleGuide', 'txtNewModule', 'btnNewModule', 'pnlModules',
               'txtSecretName', 'btnAddSecret', 'btnImportSecrets', 'txtSecretInfo', 'pnlSecrets', 'chkExportSecrets',
               'btnAddInstaller', 'txtInstallerTotal', 'pnlInstallers',
               'rbCore', 'rbCustom', 'rbNone', 'pnlCustom', 'txtFeedUrl', 'txtGitHubRepo', 'btnFillGitHub',
               'btnCheck', 'btnBuildExe', 'btnMakeUsb', 'btnExport', 'btnOpenBuilds', 'pwd1', 'pwd2', 'btnBuildLocked', 'txtOutput',
               'txtOutputDir', 'btnOutputBrowse', 'btnOutputDefault',
               'txtStatus', 'btnBack', 'btnNext', 'btnSave') {
    $ui[$n] = $win.FindName($n)
}
$pages = 0..6 | ForEach-Object { $win.FindName("page$_") }
$state = Get-WizardState
$secrets = @{ Values = [ordered]@{}; Error = $null }   # loaded in init (Get-WizardSecrets, section 4)

$coreVer = (Get-ToolkitVersionInfo -Root (Join-Path $Root 'dependencies') -Parent $Root).Core
$ui.txtCoreInfo.Text = "Core v$coreVer`n$Root"

# ---------------------------------------------------------------- navigation
function Show-Page {
    param([int]$Index)
    for ($i = 0; $i -lt $pages.Count; $i++) { $pages[$i].Visibility = if ($i -eq $Index) { 'Visible' } else { 'Collapsed' } }
    $ui.btnBack.IsEnabled = $Index -gt 0
    $ui.btnNext.Content = if ($Index -eq $pages.Count - 1) { 'Done' } else { 'Next' }
    switch ($Index) { 2 { Update-ModuleList } 3 { Update-SecretList } 4 { Update-InstallerList } }
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
    # The DPAPI store (secrets.dat) never goes into a package: it only opens for this Windows user.
    # -SecretsPassphrase: also include the secret values as secrets.pkg, encrypted with that passphrase.
    param([Parameter(Mandatory)][string]$ZipPath, [string]$SecretsPassphrase)
    $stage = Join-Path $env:TEMP "client-package-$([guid]::NewGuid().ToString('N'))"
    try {
        robocopy $ClientRoot $stage /E /XD (Join-Path $ClientRoot '_removed') (Join-Path $ClientRoot 'Data') (Join-Path $ClientRoot '.locked') /XF secrets.dat secrets.pkg /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "copy failed (robocopy $LASTEXITCODE)" }
        if ($SecretsPassphrase) {
            $filled = [ordered]@{}
            foreach ($k in $secrets.Values.Keys) { if ($secrets.Values[$k]) { $filled[$k] = $secrets.Values[$k] } }
            $json = [pscustomobject]$filled | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllBytes((Join-Path $stage 'secrets.pkg'), (Protect-ToolkitBlob -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json)) -Passphrase $SecretsPassphrase))
            $json = $null
        }
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
        if (Get-ChildItem $src -Recurse -File -Force | Where-Object { $_.Name -like '*.key' -or $_.Name -in '.toolkit-key', '.sfx-key', 'secrets.dat' }) { Show-Msg 'The package contains key files and was not imported.' 'OK' 'Error' | Out-Null; return }
        # Secret values (optional, passphrase-protected) are decrypted before anything is replaced
        $importedSecrets = $null
        $pkg = Join-Path $src 'secrets.pkg'
        if (Test-Path $pkg) {
            while ($null -eq $importedSecrets) {
                $pass = Read-Passphrase -Title 'Import secrets' -Message 'This package includes secret values. Enter the passphrase used when it was exported (Cancel imports it without the values).'
                if ($null -eq $pass) { break }
                try {
                    $plain = Unprotect-ToolkitBlob -Bytes ([System.IO.File]::ReadAllBytes($pkg)) -Passphrase $pass
                    $importedSecrets = ConvertTo-ToolkitSecretTable ([System.Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json)
                } catch { Show-Msg 'Wrong passphrase.' 'OK' 'Warning' | Out-Null }
            }
            Remove-Item -LiteralPath $pkg -Force
        }
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
        $previous = $secrets.Values   # this PC's values from before the import (secrets.dat was replaced)
        $script:secrets = Get-WizardSecrets
        foreach ($k in @($script:secrets.Values.Keys)) {
            if ($importedSecrets -and $importedSecrets.Contains($k)) { $script:secrets.Values[$k] = $importedSecrets[$k] }
            elseif (-not $script:secrets.Values[$k] -and $previous.Contains($k)) { $script:secrets.Values[$k] = $previous[$k] }
        }
        if ($importedSecrets) { foreach ($k in $importedSecrets.Keys) { if (-not $script:secrets.Values.Contains($k)) { $script:secrets.Values[$k] = $importedSecrets[$k] } } }
        Save-WizardSecrets
        $importedSecrets = $null; $previous = $null
        $missing = (Get-WizardSecretSummary).Missing
        if ($missing.Count) { Show-Msg "$($missing.Count) secret(s) need a value: $($missing -join ', ').`n`nEnter them on the Secrets page." 'OK' 'Information' | Out-Null }
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
    if (Add-ModuleFile -SourceFile $dlg.FileName) {
        Update-ModuleList
        # Offer to put the module's secrets on the Secrets page right away, so nobody has to remember them
        $p = Read-OvModuleFile $dlg.FileName
        $need = @((Get-OvModuleSecrets -Parsed $p).All | Where-Object { $n = $_; -not ($secrets.Values.Keys | Where-Object { $_ -eq $n }) })
        if ($need.Count -and (Show-Msg "This module needs these secrets: $($need -join ', ').`n`nAdd them to the Secrets page now? You then type their values there." 'YesNo' 'Question') -eq 'Yes') {
            $null = Import-WizardModuleSecrets -File $dlg.FileName
            Set-Status "Added module and $($need.Count) secret(s) - enter their values on the Secrets page."
        }
    }
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
function New-ModuleGuideText {
    # Fills tools\ClientSetup\module-guide.template.md with this client's details: a self-contained
    # brief for an AI coding agent that has never seen the toolkit.
    $template = Join-Path $PSScriptRoot 'module-guide.template.md'
    if (-not (Test-Path $template)) { throw 'module-guide.template.md is missing from tools\ClientSetup.' }
    $product = $ui.txtProductName.Text.Trim(); if (-not $product) { $product = 'Endpoint Toolkit' }
    $prefix = (($product -split '\s+') | Where-Object { $_ -match '[A-Za-z]' } | Select-Object -First 1) -replace '[^A-Za-z0-9]', ''
    if (-not $prefix -or $prefix -eq 'Endpoint') { $prefix = 'Client' }
    if ($prefix -match '^[0-9]') { $prefix = "C$prefix" }

    $core = Get-OvCoreInventory -Root $Root
    $coreRows = @('| Name | Label |', '|---|---|') + @($core.Modules | ForEach-Object { "| ``$($_.Name)`` | $($_.Label) |" })
    $clientMods = @(Get-ClientModuleInfo)
    $clientRows = if ($clientMods.Count) { @($clientMods | ForEach-Object { "- ``$($_.Name)``: $($_.Label) ($(Split-Path $_.File -Leaf))" }) } else { @('- (none yet)') }
    $fnList = (@($core.Functions.Keys | Sort-Object) | ForEach-Object { "``$_``" }) -join ', '

    $exampleFile = Join-Path $Root 'client.example\Modules\Example-Module.ps1'
    $example = if (Test-Path $exampleFile) { (Get-Content $exampleFile -Raw -Encoding UTF8).Trim() } else { '# (template not found in this kit)' }
    $example = $example.Replace('ClientExample', "${prefix}Example").Replace('Client Example', "$prefix Example").Replace('Example-Module.ps1', "$prefix-Example.ps1")

    $text = Get-Content $template -Raw -Encoding UTF8
    $values = [ordered]@{
        '{{Template}}' = $example; '{{CoreModules}}' = ($coreRows -join "`r`n"); '{{ClientModules}}' = ($clientRows -join "`r`n")
        '{{CoreFunctions}}' = $fnList; '{{ProductName}}' = $product; '{{Prefix}}' = $prefix
        '{{CoreVersion}}' = $coreVer; '{{AccentColor}}' = $ui.txtAccent.Text.Trim(); '{{Date}}' = (Get-Date -Format 'yyyy-MM-dd')
    }
    foreach ($k in $values.Keys) { $text = $text.Replace($k, [string]$values[$k]) }
    return $text
}

$ui.btnModuleGuide.Add_Click({
    try { $text = New-ModuleGuideText } catch { Show-Msg "Could not create the guide: $($_.Exception.Message)" 'OK' 'Error' | Out-Null; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $safe = ($ui.txtProductName.Text.Trim() -replace '[^A-Za-z0-9]+', '-').Trim('-'); if (-not $safe) { $safe = 'toolkit' }
    $dlg.FileName = "$safe-MODULE-GUIDE.md"; $dlg.Filter = 'Markdown (*.md)|*.md'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if (-not $dlg.ShowDialog($win)) { return }
    $full = [System.IO.Path]::GetFullPath($dlg.FileName)
    if ($full.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        Show-Msg 'Save the guide outside the toolkit folder (for example in Documents or your module project). Extra files inside the toolkit folder block builds.' 'OK' 'Warning' | Out-Null; return
    }
    [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding $false))
    Set-Status "Module guide saved: $full"
    if ((Show-Msg "Saved $(Split-Path $full -Leaf).`n`nGive this file to your AI coding agent (for example put it in the folder where you write the module, or paste it into the chat). When the module is ready, add it here with 'Add module file...'.`n`nOpen it now?" 'YesNo' 'Question') -eq 'Yes') {
        Start-Process notepad.exe -ArgumentList "`"$full`""
    }
})

$ui.btnLockAll.Add_Click({ $state.LockAll = $true; Save-WizardState -Quiet; Update-ModuleList })
$ui.btnUnlockAll.Add_Click({ $state.LockAll = $false; $state.Locked.Clear(); Save-WizardState -Quiet; Update-ModuleList })

# ---------------------------------------------------------------- 4 secrets
# Values live in client\secrets.dat (Windows DPAPI, this Windows user only). Names are also kept in
# client\secrets-names.json (names only, safe for git) so a clone or an imported package knows which
# values still have to be typed in. Neither file ships in any build (Get-ToolkitPayloadExcludes);
# locked builds put the values into the encrypted vault (dependencies\Agent\LockedPayload.ps1).
function Get-WizardSecrets {
    $s = @{ Values = [ordered]@{}; Error = $null }
    if (-not (Test-Path $ClientRoot)) { return $s }
    try { $s.Values = Read-ToolkitSecretStore -ClientRoot $ClientRoot }
    catch { $s.Error = 'client\secrets.dat was saved by another Windows user or PC, so its values cannot be read here. Enter them again; saving replaces that file.' }
    $namesPath = Join-Path $ClientRoot 'secrets-names.json'
    if (Test-Path $namesPath) {
        # assign first: PS 5.1 ConvertFrom-Json emits a JSON array as one pipeline object
        try { $list = Get-Content $namesPath -Raw | ConvertFrom-Json; foreach ($n in @($list)) { if ($n -and -not $s.Values.Contains("$n")) { $s.Values["$n"] = '' } } } catch { }
    }
    return $s
}

function Save-WizardSecrets {
    if (-not (Test-Path $ClientRoot)) { return }
    $filled = [ordered]@{}
    foreach ($k in $secrets.Values.Keys) { if ($secrets.Values[$k]) { $filled[$k] = $secrets.Values[$k] } }
    # An unreadable store (other user) is only replaced once there is something to replace it with
    if (-not ($secrets.Error -and $filled.Count -eq 0)) {
        $null = Get-ClientPath 'secrets.dat'
        Save-ToolkitSecretStore -ClientRoot $ClientRoot -Secrets $filled
        if ($filled.Count -gt 0) { $secrets.Error = $null }
    }
    $namesPath = Get-ClientPath 'secrets-names.json'
    $names = @($secrets.Values.Keys | Sort-Object)
    if ($names.Count -eq 0) { Remove-Item -LiteralPath $namesPath -Force -ErrorAction SilentlyContinue }
    else { [System.IO.File]::WriteAllText($namesPath, (ConvertTo-Json -InputObject $names), (New-Object System.Text.UTF8Encoding $false)) }
}

function Get-WizardSecretSummary {
    $missing = @($secrets.Values.Keys | Where-Object { -not $secrets.Values[$_] })
    return @{ Count = $secrets.Values.Count; Missing = $missing }
}

function Update-SecretList {
    $ui.pnlSecrets.Children.Clear()
    foreach ($name in @($secrets.Values.Keys)) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        foreach ($w in '220', '*', '70', '90') {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::new([double]$w) }
            $g.ColumnDefinitions.Add($cd)
        }
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $name; $t.VerticalAlignment = 'Center'; $t.FontFamily = 'Consolas'
        $t.ToolTip = "In a module: Get-ToolkitSecret '$name'"

        $pb = New-Object System.Windows.Controls.PasswordBox
        $pb.Password = [string]$secrets.Values[$name]; $pb.Tag = $name; $pb.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
        $pb.Add_PasswordChanged({ $secrets.Values[$this.Tag] = $this.Password })
        $pb.Add_LostFocus({ Save-WizardSecrets; Update-SecretInfo })
        [System.Windows.Controls.Grid]::SetColumn($pb, 1)

        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Visibility = 'Collapsed'; $tb.Tag = $name; $tb.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
        $tb.Add_TextChanged({ $secrets.Values[$this.Tag] = $this.Text })
        $tb.Add_LostFocus({ Save-WizardSecrets; Update-SecretInfo })
        [System.Windows.Controls.Grid]::SetColumn($tb, 1)

        $show = New-Object System.Windows.Controls.Button
        $show.Content = 'Show'; $show.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2); $show.Tag = @{ Pb = $pb; Tb = $tb }
        $show.Add_Click({
            $p = $this.Tag.Pb; $x = $this.Tag.Tb
            if ($p.Visibility -eq 'Visible') { $x.Text = $p.Password; $p.Visibility = 'Collapsed'; $x.Visibility = 'Visible'; $this.Content = 'Hide' }
            else { $p.Password = $x.Text; $x.Text = ''; $x.Visibility = 'Collapsed'; $p.Visibility = 'Visible'; $this.Content = 'Show' }
        })
        [System.Windows.Controls.Grid]::SetColumn($show, 2)

        $rm = New-Object System.Windows.Controls.Button
        $rm.Content = 'Remove'; $rm.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2); $rm.Tag = $name
        $rm.Add_Click({
            if ((Show-Msg "Remove the secret '$($this.Tag)'?`n`nModules that read it get nothing until you add it again." 'YesNo' 'Question') -ne 'Yes') { return }
            $secrets.Values.Remove($this.Tag)
            Save-WizardSecrets; Update-SecretList; Set-Status "Removed secret $($this.Tag)."
        })
        [System.Windows.Controls.Grid]::SetColumn($rm, 3)
        foreach ($el in $t, $pb, $tb, $show, $rm) { $g.Children.Add($el) | Out-Null }
        $ui.pnlSecrets.Children.Add($g) | Out-Null
    }
    Update-SecretInfo
}

function Update-SecretInfo {
    $sum = Get-WizardSecretSummary
    $ui.txtSecretInfo.Text = if ($secrets.Error) { $secrets.Error }
        elseif ($sum.Count -eq 0) { 'No secrets yet.' }
        elseif ($sum.Missing.Count) { "$($sum.Count) secret(s); $($sum.Missing.Count) still need a value: $($sum.Missing -join ', ')" }
        else { "$($sum.Count) secret(s), all set." }
    $ui.txtSecretInfo.Foreground = New-Brush $(if ($secrets.Error -or $sum.Missing.Count) { '#FFF9E2AF' } else { '#FFA6ADC8' })
}

$ui.btnAddSecret.Add_Click({
    $n = $ui.txtSecretName.Text.Trim()
    if ($n -notmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') { Show-Msg 'A secret name starts with a letter and uses only letters, digits and _ (for example RmmSiteKey).' 'OK' 'Warning' | Out-Null; return }
    if ($secrets.Values.Keys | Where-Object { $_ -eq $n }) { Show-Msg "There is already a secret named '$n'." 'OK' 'Warning' | Out-Null; return }
    if ($state.IsNew) { Save-WizardState -Quiet }   # creates client\
    $secrets.Values[$n] = ''
    $ui.txtSecretName.Text = ''
    Save-WizardSecrets; Update-SecretList
    Set-Status "Added secret $n - type its value in the list."
})

function Import-WizardModuleSecrets {
    # Adds every secret a module file needs (its Secrets = @(...) list and its Get-ToolkitSecret calls) to the
    # Secrets page with an empty value. Values already entered are kept. Returns @{ Ok; Added; Existing; Invalid; Error }.
    param([Parameter(Mandatory)][string]$File)
    $p = Read-OvModuleFile $File
    if ($p.Errors.Count) { return @{ Ok = $false; Error = "The file has a syntax error (line $($p.Errors[0].Extent.StartLineNumber))." } }
    $sec = Get-OvModuleSecrets -Parsed $p
    $added = @(); $existing = @()
    foreach ($n in $sec.All) {
        if ($secrets.Values.Keys | Where-Object { $_ -eq $n }) { $existing += $n } else { $added += $n }
    }
    if ($added.Count) {
        if ($state.IsNew) { Save-WizardState -Quiet }   # creates client\
        foreach ($n in $added) { $secrets.Values[$n] = '' }
        Save-WizardSecrets; Update-SecretList
    }
    return @{ Ok = $true; Added = $added; Existing = $existing; Invalid = $sec.Invalid; Error = $null }
}

$ui.btnImportSecrets.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'PowerShell module (*.ps1)|*.ps1'
    $modulesDir = Join-Path $ClientRoot 'Modules'
    if (Test-Path $modulesDir) { $dlg.InitialDirectory = $modulesDir }
    if (-not $dlg.ShowDialog($win)) { return }
    $leaf = Split-Path $dlg.FileName -Leaf
    $r = Import-WizardModuleSecrets -File $dlg.FileName
    if (-not $r.Ok) { Show-Msg "$leaf could not be read: $($r.Error)" 'OK' 'Error' | Out-Null; return }
    $lines = @()
    if ($r.Added.Count)    { $lines += "Added: $($r.Added -join ', ')`nType a value for each one in the list." }
    if ($r.Existing.Count) { $lines += "Already on this page: $($r.Existing -join ', ')" }
    if ($r.Invalid.Count)  { $lines += "Not readable (use plain names in quotes): $($r.Invalid -join ', ')" }
    if (-not $lines.Count) { $lines += "$leaf doesn't list any secrets.`n`nA module lists the secrets it needs in its Register function, for example:`n    Secrets = @('RmmSiteKey', 'RmmApiToken')" }
    Show-Msg ($lines -join "`n`n") 'OK' $(if ($r.Added.Count) { 'Information' } else { 'None' }) | Out-Null
    Set-Status "$leaf : $($r.Added.Count) secret(s) added, $($r.Existing.Count) already present."
})

function Read-Passphrase {
    # Small modal passphrase prompt. Returns the text, or $null when cancelled. -Confirm asks twice.
    param([string]$Title, [string]$Message, [switch]$Confirm)
    $w = New-Object System.Windows.Window
    $w.Title = $Title; $w.SizeToContent = 'WidthAndHeight'; $w.ResizeMode = 'NoResize'; $w.Owner = $win
    $w.WindowStartupLocation = 'CenterOwner'; $w.Background = New-Brush '#FF1E1E2E'
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = [System.Windows.Thickness]::new(18); $sp.Width = 360
    $msg = New-Object System.Windows.Controls.TextBlock; $msg.Text = $Message; $msg.TextWrapping = 'Wrap'; $msg.Foreground = New-Brush '#FFCDD6F4'; $msg.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $p1 = New-Object System.Windows.Controls.PasswordBox; $p1.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $p2 = New-Object System.Windows.Controls.PasswordBox; $p2.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $hint2 = New-Object System.Windows.Controls.TextBlock; $hint2.Text = 'Confirm:'; $hint2.Foreground = New-Brush '#FFA6ADC8'
    $btns = New-Object System.Windows.Controls.StackPanel; $btns.Orientation = 'Horizontal'; $btns.HorizontalAlignment = 'Right'
    $ok = New-Object System.Windows.Controls.Button; $ok.Content = 'OK'; $ok.IsDefault = $true; $ok.Padding = [System.Windows.Thickness]::new(16, 4, 16, 4); $ok.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $cancel = New-Object System.Windows.Controls.Button; $cancel.Content = 'Cancel'; $cancel.IsCancel = $true; $cancel.Padding = [System.Windows.Thickness]::new(16, 4, 16, 4)
    $ok.Add_Click({ $w.DialogResult = $true })
    $btns.Children.Add($ok) | Out-Null; $btns.Children.Add($cancel) | Out-Null
    $sp.Children.Add($msg) | Out-Null; $sp.Children.Add($p1) | Out-Null
    if ($Confirm) { $sp.Children.Add($hint2) | Out-Null; $sp.Children.Add($p2) | Out-Null }
    $sp.Children.Add($btns) | Out-Null
    $w.Content = $sp
    $w.Add_ContentRendered({ $p1.Focus() | Out-Null })
    if (-not $w.ShowDialog()) { return $null }
    $a = $p1.Password
    $problem = if ($Confirm -and $a.Length -lt 8) { 'Use a passphrase of at least 8 characters.' }
               elseif ($Confirm -and $a -cne $p2.Password) { 'The two passphrases do not match.' }
               elseif (-not $a) { 'Enter the passphrase.' }
    if (-not $problem) { return $a }
    Show-Msg $problem 'OK' 'Warning' | Out-Null
    return Read-Passphrase -Title $Title -Message $Message -Confirm:$Confirm   # a closed Window can't be reopened
}

# ---------------------------------------------------------------- 5 installers
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

# ---------------------------------------------------------------- 6 updates
function Update-UpdateControls { $ui.pnlCustom.IsEnabled = [bool]$ui.rbCustom.IsChecked }
foreach ($rb in $ui.rbCore, $ui.rbCustom, $ui.rbNone) { $rb.Add_Checked({ Update-UpdateControls }) }
$ui.btnFillGitHub.Add_Click({
    $repo = $ui.txtGitHubRepo.Text.Trim().Trim('/') -replace '^https?://github\.com/', ''
    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') { Show-Msg 'Enter the repository as owner/name, for example acme-it/acme-toolkit.' | Out-Null; return }
    $ui.txtFeedUrl.Text = "https://github.com/$repo/releases/latest/download"
})

# ---------------------------------------------------------------- 7 check & build
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

# Build output folder: chosen on the Check & Build page, remembered on this PC in _builds\client-setup.json
# (never in client\, which ships). Empty or "Default" = the toolkit's _builds folder.
$script:WizardSettingsPath = Join-Path $BuildsRoot 'client-setup.json'
function Read-WizardSettings {
    if (-not (Test-Path $script:WizardSettingsPath)) { return @{} }
    try { $j = Get-Content $script:WizardSettingsPath -Raw | ConvertFrom-Json; $h = @{}; foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = $p.Value }; return $h } catch { return @{} }
}
function Save-WizardSetting {
    param([string]$Name, $Value)
    $h = Read-WizardSettings; $h[$Name] = $Value
    New-Item -ItemType Directory -Path $BuildsRoot -Force | Out-Null
    [System.IO.File]::WriteAllText($script:WizardSettingsPath, ([pscustomobject]$h | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
}
function Get-BuildOutputDir {
    # The chosen output folder, created if needed and remembered; $null (after a message) when it can't be used.
    $dir = $ui.txtOutputDir.Text.Trim().Trim('"')
    if (-not $dir) { $dir = $BuildsRoot }
    $why = Test-ToolkitBuildOutputPath -Root $Root -Path $dir
    if ($why) { Show-Msg $why 'OK' 'Warning' | Out-Null; return $null }
    $dir = [System.IO.Path]::GetFullPath($dir).TrimEnd('\')
    if ($dir.Length -eq 2) { $dir += '\' }   # drive root (D:)
    try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    catch { Show-Msg "The output folder can't be created: $($_.Exception.Message)" 'OK' 'Warning' | Out-Null; return $null }
    $ui.txtOutputDir.Text = $dir
    Save-WizardSetting 'OutputDir' $(if ($dir -eq $BuildsRoot) { '' } else { $dir })
    return $dir
}
$saved = (Read-WizardSettings)['OutputDir']
$ui.txtOutputDir.Text = if ($saved) { "$saved" } else { $BuildsRoot }
$ui.btnOutputBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Where should builds go? (outside the toolkit folder)'
    $dlg.ShowNewFolderButton = $true
    $current = $ui.txtOutputDir.Text.Trim()
    if ($current -and (Test-Path $current)) { $dlg.SelectedPath = $current }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $ui.txtOutputDir.Text = $dlg.SelectedPath
    if (Get-BuildOutputDir) { Set-Status "Builds go to $($ui.txtOutputDir.Text)" }
})
$ui.btnOutputDefault.Add_Click({ $ui.txtOutputDir.Text = $BuildsRoot; if (Get-BuildOutputDir) { Set-Status "Builds go to $BuildsRoot" } })

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
    $lockedClient = @(Get-ClientModuleInfo | Where-Object { $_.RequiresAuth -or $state.LockAll -or $state.Locked.Contains($_.Name) })
    $secretCount = (Get-WizardSecretSummary).Count
    if ($lockedClient.Count -or $secretCount) {
        $msg = "The plain exe and folder build have no password:`n"
        if ($lockedClient.Count) { $msg += "`n - your locked modules ($(($lockedClient | ForEach-Object { $_.Label }) -join ', ')) are LEFT OUT of them" }
        if ($secretCount) { $msg += "`n - your $secretCount secret(s) are NOT included, so modules that need them won't work" }
        $msg += "`n`nUse 'Build locked exe' to ship them with a password. Build the plain exe and folder without them?"
        if ((Show-Msg $msg 'YesNo' 'Warning') -ne 'Yes') { return }
    }
    $out = Get-BuildOutputDir; if (-not $out) { return }
    Step-VersionIfRebuilt
    Start-BuildJob -Title 'Build exe' -ScriptPath (Join-Path $Root 'build.ps1') -Params @{ SFX = $true; Folder = $true; OutputPath = $out } -SuccessNote "Output: $out (the exe, plus a v<version> folder with a ready-to-run copy: run Launch.bat inside it)"
})
$ui.btnBuildLocked.Add_Click({
    if ($ui.pwd1.SecurePassword.Length -lt 8) { Show-Msg 'The password must be at least 8 characters.' 'OK' 'Warning' | Out-Null; return }
    $p1 = [System.Net.NetworkCredential]::new('', $ui.pwd1.SecurePassword).Password
    $p2 = [System.Net.NetworkCredential]::new('', $ui.pwd2.SecurePassword).Password
    $same = $p1 -ceq $p2; $p1 = $null; $p2 = $null
    if (-not $same) { Show-Msg 'The two passwords do not match.' 'OK' 'Warning' | Out-Null; return }
    if (-not (Invoke-FullCheck)) { return }
    $out = Get-BuildOutputDir; if (-not $out) { return }
    Step-VersionIfRebuilt
    $secure = $ui.pwd1.SecurePassword.Copy()
    $ui.pwd1.Clear(); $ui.pwd2.Clear()
    Start-BuildJob -Title 'Build locked exe' -ScriptPath (Join-Path $Root 'dependencies\Agent\Export-LockedToolkit.ps1') -Params @{ Password = $secure; OutputPath = $out } -SuccessNote "Output: $out"
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
    $pass = $null
    if ($ui.chkExportSecrets.IsChecked -and (Get-WizardSecretSummary).Count -gt 0) {
        $pass = Read-Passphrase -Title 'Protect secrets' -Message 'Choose a passphrase for the secret values in this package (at least 8 characters). You need it to import the package. Without it the values cannot be recovered.' -Confirm
        if ($null -eq $pass) { return }
    }
    try {
        Export-ClientPackage -ZipPath $full -SecretsPassphrase $pass
        $what = if ($pass) { ' (secret values included, passphrase-protected)' } elseif ((Get-WizardSecretSummary).Count) { ' (secret names only - values stay on this PC)' } else { '' }
        Write-Output2 "Client package saved: $full$what"; Set-Status 'Client package exported.'
    }
    catch { Show-Msg "Export failed: $($_.Exception.Message)" 'OK' 'Error' | Out-Null }
})
$ui.btnOpenBuilds.Add_Click({ $out = Get-BuildOutputDir; if ($out) { Start-Process explorer.exe -ArgumentList "`"$out`"" } })

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
$secrets = Get-WizardSecrets
Initialize-Controls
$null = Update-Integrity
$ui.lstSteps.SelectedIndex = 0
Show-Page 0
if ($state.IsNew) { Set-Status 'New client - nothing is written until you click Next or Save.' } else { Set-Status "Loaded client\ (v$($state.Version))." }

$win.ShowDialog() | Out-Null
