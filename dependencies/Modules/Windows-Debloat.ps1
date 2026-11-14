# Module: Windows-Debloat.ps1 — Bloatware removal, telemetry/UI tweaks, USB power management, Office C2R cleanup, McAfee removal

function Register-WindowsDebloat {
    @{
        Name         = 'Windows-Debloat'
        Label        = 'Debloat & Tweaks'
        Description  = 'Remove bloatware apps and McAfee trialware, disable telemetry, and fix USB power management'
        RequiresAuth = $false
        SortOrder    = 25
        EntryPoint   = 'Start-WindowsDebloat'
        UIDefinition = 'Get-WindowsDebloatUI'
    }
}

# Static catalog: bloatware apps, telemetry/privacy tweaks, UI tweaks, and system actions.
# Office Click-to-Run entries are discovered dynamically at UI-render time (see Get-InstalledOfficeC2R).
function Get-DebloatCatalog {
    @(
        # ===== Bloatware Apps (Appx + provisioned, so it doesn't reinstall for new profiles) =====
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Xbox Game Bar';        AppxName = 'Microsoft.XboxGamingOverlay';       ProvisionedName = 'Microsoft.XboxGamingOverlay*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Xbox App';             AppxName = 'Microsoft.GamingApp';                ProvisionedName = 'Microsoft.GamingApp*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Xbox App (legacy)';    AppxName = 'Microsoft.XboxApp';                  ProvisionedName = 'Microsoft.XboxApp*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Solitaire Collection'; AppxName = 'Microsoft.MicrosoftSolitaireCollection'; ProvisionedName = 'Microsoft.MicrosoftSolitaireCollection*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Candy Crush Saga';     AppxName = 'king.com.CandyCrushSaga';            ProvisionedName = 'king.com.CandyCrushSaga*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Candy Crush Soda Saga';AppxName = 'king.com.CandyCrushSodaSaga';        ProvisionedName = 'king.com.CandyCrushSodaSaga*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = '3D Viewer';            AppxName = 'Microsoft.Microsoft3DViewer';        ProvisionedName = 'Microsoft.Microsoft3DViewer*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Mixed Reality Portal'; AppxName = 'Microsoft.MixedReality.Portal';      ProvisionedName = 'Microsoft.MixedReality.Portal*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Skype';                AppxName = 'Microsoft.SkypeApp';                 ProvisionedName = 'Microsoft.SkypeApp*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'People';               AppxName = 'Microsoft.People';                   ProvisionedName = 'Microsoft.People*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Maps';                 AppxName = 'Microsoft.WindowsMaps';              ProvisionedName = 'Microsoft.WindowsMaps*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Clipchamp';            AppxName = 'Clipchamp.Clipchamp';                ProvisionedName = 'Clipchamp.Clipchamp*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Family';               AppxName = 'MicrosoftCorporationII.MicrosoftFamily'; ProvisionedName = 'MicrosoftCorporationII.MicrosoftFamily*' }
        @{ Category = 'Bloatware Apps'; Type = 'Appx'; Name = 'Weather';              AppxName = 'Microsoft.BingWeather';              ProvisionedName = 'Microsoft.BingWeather*' }

        # ===== Telemetry & Privacy (registry policy keys) =====
        @{ Category = 'Telemetry & Privacy'; Type = 'Registry'; Name = 'Diagnostic Data (set to Basic)'; RegOps = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = 1; PropertyType = 'DWord' }
        ) }
        @{ Category = 'Telemetry & Privacy'; Type = 'Registry'; Name = 'Tailored Experiences with Diagnostic Data'; RegOps = @(
            @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData'; Value = 1; PropertyType = 'DWord' }
        ) }
        @{ Category = 'Telemetry & Privacy'; Type = 'Registry'; Name = 'Advertising ID'; RegOps = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0; PropertyType = 'DWord' }
        ) }
        @{ Category = 'Telemetry & Privacy'; Type = 'Registry'; Name = 'Activity History / Timeline'; RegOps = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed';     Value = 0; PropertyType = 'DWord' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities';  Value = 0; PropertyType = 'DWord' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities';   Value = 0; PropertyType = 'DWord' }
        ) }
        @{ Category = 'Telemetry & Privacy'; Type = 'Registry'; Name = 'Feedback Prompts'; RegOps = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; Value = 0; PropertyType = 'DWord' }
        ) }
        @{ Category = 'Telemetry & Privacy'; Type = 'Registry'; Name = 'Windows Copilot'; RegOps = @(
            @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1; PropertyType = 'DWord' }
        ) }
        @{ Category = 'Telemetry & Privacy'; Type = 'Registry'; Name = 'Windows Recall'; RegOps = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis';  Value = 1; PropertyType = 'DWord' }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement';  Value = 0; PropertyType = 'DWord' }
        ) }

        # ===== Start Menu / Taskbar / Lock Screen =====
        @{ Category = 'Start Menu / Taskbar / Lock Screen'; Type = 'Registry'; Name = 'Start Menu Suggested Apps / Ads'; RegOps = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled';       Value = 0; PropertyType = 'DWord' }
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled';     Value = 0; PropertyType = 'DWord' }
        ) }
        @{ Category = 'Start Menu / Taskbar / Lock Screen'; Type = 'Registry'; Name = 'Meet Now Icon (Taskbar)'; RegOps = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'HideSCAMeetNow'; Value = 1; PropertyType = 'DWord' }
        ) }
        @{ Category = 'Start Menu / Taskbar / Lock Screen'; Type = 'Registry'; Name = 'Widgets Icon (Taskbar)'; RegOps = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarDa'; Value = 0; PropertyType = 'DWord' }
        ) }
        @{ Category = 'Start Menu / Taskbar / Lock Screen'; Type = 'Registry'; Name = 'Lock Screen Tips / Spotlight Ads'; RegOps = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenOverlayEnabled'; Value = 0; PropertyType = 'DWord' }
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338387Enabled';   Value = 0; PropertyType = 'DWord' }
        ) }
        @{ Category = 'Start Menu / Taskbar / Lock Screen'; Type = 'Registry'; Name = 'Bing Results in Start Search'; RegOps = @(
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Value = 0; PropertyType = 'DWord' }
            @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1; PropertyType = 'DWord' }
        ) }

        # ===== System Tweaks =====
        @{ Category = 'System Tweaks'; Type = 'Action'; Name = 'Disable USB Power Management (all USB controllers)'; Action = 'Disable-UsbPowerManagement' }
        @{ Category = 'System Tweaks'; Type = 'Action'; Name = 'Disable Fast Startup and Hibernation'; Action = 'Disable-FastStartupAndHibernation' }

        # ===== McAfee Removal (OEM trialware) =====
        @{ Category = 'McAfee Removal'; Type = 'Action'; Name = 'Remove McAfee Products (PC)'; Action = 'Remove-McAfeeProducts' }
        @{ Category = 'McAfee Removal'; Type = 'Action'; Name = 'Remove McAfee WebAdvisor (Chrome / Edge / Firefox)'; Action = 'Remove-McAfeeBrowserExtensions' }
    )
}

# Applies a single registry value, creating the key path if it doesn't already exist.
function Set-DebloatRegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$PropertyType)

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force | Out-Null
}

# Disables power management on every currently-present USB controller/hub, matching the
# Device Manager "Allow the computer to turn off this device to save power" checkbox.
# Also disables the USB selective suspend power scheme setting on AC and battery.
function Disable-UsbPowerManagement {
    $usbDevices = Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass = 'USB'" -ErrorAction SilentlyContinue
    $usbDeviceIds = @($usbDevices | ForEach-Object { $_.PNPDeviceID })

    $changed = 0
    Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue | ForEach-Object {
        $instanceId = ($_.InstanceName -replace '_\d+$', '')
        if ($usbDeviceIds -contains $instanceId) {
            try {
                Set-CimInstance -InputObject $_ -Property @{ Enable = $false } -ErrorAction Stop
                $changed++
            } catch { }
        }
    }

    # USB selective suspend (subgroup 2a737441-1930-4402-8d77-b2bebba308a3, setting 48e6b7a6-50f5-4782-a5d4-53bb8f07e226)
    $subgroup = '2a737441-1930-4402-8d77-b2bebba308a3'
    $setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    & powercfg /setacvalueindex SCHEME_CURRENT $subgroup $setting 0 2>&1 | Out-Null
    & powercfg /setdcvalueindex SCHEME_CURRENT $subgroup $setting 0 2>&1 | Out-Null
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null

    return $changed
}

# Turns off Windows Fast Startup (HiberbootEnabled, plus the matching policy value so it stays off)
# and hibernation (powercfg /hibernate off, which also removes hiberfil.sys). Takes effect after a restart.
function Disable-FastStartupAndHibernation {
    $powerKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'

    Set-DebloatRegistryValue -Path $powerKey -Name 'HiberbootEnabled' -Value 0 -PropertyType 'DWord'
    Set-DebloatRegistryValue -Path $policyKey -Name 'HiberbootEnabled' -Value 0 -PropertyType 'DWord'

    & powercfg /hibernate off 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg /hibernate off failed (exit code $LASTEXITCODE)"
    }

    Write-Log '  Restart required for Fast Startup / hibernation changes to take effect' -Level Warning
}

# Removes McAfee OEM trialware (LiveSafe / Total Protection / Security, etc.) by enumerating the
# uninstall registry for DisplayName -like 'McAfee*' and invoking each product's own (quiet) uninstaller.
# No bundled removal tool - registry-only, to keep the toolkit lightweight.
function Remove-McAfeeProducts {
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entries = foreach ($path in $uninstallPaths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'McAfee*' }
    }

    $removed = 0
    foreach ($entry in $entries) {
        $isQuiet = [bool]$entry.QuietUninstallString
        $cmd = if ($isQuiet) { $entry.QuietUninstallString } else { $entry.UninstallString }
        if (-not $cmd) { continue }

        if (-not $isQuiet) {
            if ($cmd -match '(?i)msiexec' -and $cmd -notmatch '(?i)/q') {
                $cmd += ' /qn /norestart'
            } elseif ($cmd -notmatch '(?i)msiexec' -and $cmd -notmatch '(?i)(/s\b|/silent|/quiet)') {
                $cmd += ' /silent /uninstall'
            }
        }

        if ($cmd -match '^"([^"]+)"(.*)$') {
            $exe = $Matches[1]; $exeArgs = $Matches[2].Trim()
        } else {
            $parts = $cmd -split ' ', 2
            $exe = $parts[0]; $exeArgs = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        }

        try {
            $proc = Start-Process -FilePath $exe -ArgumentList $exeArgs -Wait -PassThru -ErrorAction Stop
            Write-Log "  Removed $($entry.DisplayName) (exit code $($proc.ExitCode))" -Level Success
            $removed++
        } catch {
            Write-Log "  Failed to remove $($entry.DisplayName): $($_.Exception.Message)" -Level Error
        }
    }

    if (@($entries).Count -eq 0) {
        Write-Log '  No McAfee products found' -Level Info
    }

    return $removed
}

# Removes the McAfee WebAdvisor extension from Chrome, Edge, and Firefox. Discovers it dynamically by
# scanning each browser's installed-extension manifests for "mcafee"/"webadvisor" (no hardcoded extension IDs),
# then cleans up both the local extension files and any registry force-install/external registration.
function Remove-McAfeeBrowserExtensions {
    $removed = 0

    $chromiumBrowsers = @(
        @{ Name = 'Chrome'; UserDataDir = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'; RegRoots = @('HKLM:\SOFTWARE\Google\Chrome\Extensions', 'HKLM:\SOFTWARE\WOW6432Node\Google\Chrome\Extensions'); ForceListRoots = @('HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist') }
        @{ Name = 'Edge';   UserDataDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data';   RegRoots = @('HKLM:\SOFTWARE\Microsoft\Edge\Extensions', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge\Extensions');     ForceListRoots = @('HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist') }
    )

    foreach ($browser in $chromiumBrowsers) {
        if (-not (Test-Path $browser.UserDataDir)) { continue }

        # Find McAfee extension IDs by reading manifests from each profile's local Extensions cache
        $mcafeeIds = [System.Collections.Generic.HashSet[string]]::new()
        Get-ChildItem -Path $browser.UserDataDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $extRoot = Join-Path $_.FullName 'Extensions'
            if (-not (Test-Path $extRoot)) { return }

            Get-ChildItem -Path $extRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $extId = $_.Name
                $manifest = Get-ChildItem -Path $_.FullName -Filter 'manifest.json' -Recurse -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $manifest) { return }

                try {
                    $json = Get-Content $manifest.FullName -Raw | ConvertFrom-Json
                    $name = "$($json.name) $($json.short_name) $($json.description)"
                    if ($name -match '(?i)mcafee|webadvisor') {
                        [void]$mcafeeIds.Add($extId)
                        Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                } catch { }
            }
        }

        foreach ($extId in $mcafeeIds) {
            foreach ($root in $browser.RegRoots) {
                $key = Join-Path $root $extId
                if (Test-Path $key) {
                    Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            foreach ($listRoot in $browser.ForceListRoots) {
                if (-not (Test-Path $listRoot)) { continue }
                $props = Get-ItemProperty -Path $listRoot -ErrorAction SilentlyContinue
                if (-not $props) { continue }
                $props.PSObject.Properties |
                    Where-Object { $_.Name -notmatch '^PS' -and $_.Value -like "$extId;*" } |
                    ForEach-Object { Remove-ItemProperty -Path $listRoot -Name $_.Name -ErrorAction SilentlyContinue }
            }
            Write-Log "  Removed $($browser.Name) extension $extId" -Level Success
            $removed++
        }
    }

    # Firefox: scan extensions.json per profile for McAfee/WebAdvisor add-ons
    $ffProfilesRoot = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
    if (Test-Path $ffProfilesRoot) {
        Get-ChildItem -Path $ffProfilesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $profileDir = $_.FullName
            $extJsonPath = Join-Path $profileDir 'extensions.json'
            if (-not (Test-Path $extJsonPath)) { return }

            try {
                $extJson = Get-Content $extJsonPath -Raw | ConvertFrom-Json
                $mcafeeAddons = $extJson.addons | Where-Object {
                    ($_.defaultLocale.name -match '(?i)mcafee|webadvisor') -or ($_.id -match '(?i)mcafee')
                }
                foreach ($addon in $mcafeeAddons) {
                    $xpiPath = Join-Path $profileDir "extensions\$($addon.id).xpi"
                    if (Test-Path $xpiPath) { Remove-Item -Path $xpiPath -Force -ErrorAction SilentlyContinue }
                    Write-Log "  Removed Firefox extension $($addon.id) (profile $($_.Name))" -Level Success
                    $removed++
                }
            } catch { }
        }
    }

    if ($removed -gt 0) {
        Write-Log '  Restart affected browsers for the extension removal to take effect' -Level Warning
    } else {
        Write-Log '  No McAfee browser extensions found' -Level Info
    }

    return $removed
}

# Discovers installed Office Click-to-Run products/languages by reading the uninstall registry
# entries whose UninstallString points at OfficeClickToRun.exe — the same data Programs & Features reads.
function Get-InstalledOfficeC2R {
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $results = [System.Collections.ArrayList]::new()
    $seen = @{}

    foreach ($path in $uninstallPaths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.UninstallString -like '*OfficeClickToRun.exe*' } |
            ForEach-Object {
                if ($_.UninstallString -match 'productstoremove=([^.\s]+)\.\d+_([a-zA-Z-]+)_x-none') {
                    $productId = $Matches[1]
                    $culture = $Matches[2]
                    $key = "$productId|$culture"
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = $true
                        $results.Add(@{
                            Category    = 'Office Click-to-Run Cleanup'
                            Type        = 'OfficeC2R'
                            Name        = if ($_.DisplayName) { $_.DisplayName } else { "$productId - $culture" }
                            ProductId   = $productId
                            Culture     = $culture
                        }) | Out-Null
                    }
                }
            }
    }

    return $results
}

# Builds a single ODT configuration XML removing every selected product/language, then runs
# `setup.exe /configure` once for the entire selection (this is what collapses the ~5-minutes-per-language
# Programs & Features removal into a single Click-to-Run operation).
function Remove-OfficeC2RSelection {
    param([array]$Selection, [string]$SetupExePath)

    if (-not $Selection -or $Selection.Count -eq 0) { return $true }

    if (-not (Test-Path $SetupExePath)) {
        Write-Log "  Office Deployment Tool not found at $SetupExePath - place setup.exe there to enable Office C2R cleanup" -Level Error
        return $false
    }

    $grouped = $Selection | Group-Object -Property ProductId
    $xmlLines = @('<Configuration>', '  <Remove>')
    foreach ($group in $grouped) {
        $xmlLines += "    <Product ID=`"$($group.Name)`">"
        foreach ($item in $group.Group) {
            $xmlLines += "      <Language ID=`"$($item.Culture)`" />"
        }
        $xmlLines += '    </Product>'
    }
    $xmlLines += '  </Remove>'
    $xmlLines += '</Configuration>'

    $xmlPath = Join-Path $env:TEMP "odt-remove-office-$([guid]::NewGuid().ToString('N')).xml"
    $xmlLines -join "`r`n" | Set-Content -Path $xmlPath -Encoding UTF8

    try {
        $proc = Start-Process -FilePath $SetupExePath -ArgumentList "/configure `"$xmlPath`"" -Wait -PassThru
        return ($proc.ExitCode -eq 0)
    } finally {
        Remove-Item -Path $xmlPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-WindowsDebloatUI {
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)

    # Header
    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = 'Debloat & Tweaks'
    $header.FontSize = 22
    $header.FontWeight = 'Bold'
    $header.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#89B4FA'))
    $header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $panel.Children.Add($header) | Out-Null

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = 'Remove bloatware apps, disable telemetry, tune Start/taskbar/lock screen, fix USB power management, and clean up extra Office Click-to-Run languages.'
    $desc.FontSize = 13
    $desc.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#A6ADC8'))
    $desc.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    $desc.TextWrapping = 'Wrap'
    $panel.Children.Add($desc) | Out-Null

    # Build catalog: static items + dynamically discovered Office C2R installs
    $catalog = @(Get-DebloatCatalog)
    $officeItems = Get-InstalledOfficeC2R
    if ($officeItems.Count -gt 0) {
        $catalog += $officeItems
    }

    # Buttons row
    $btnRow = New-Object System.Windows.Controls.WrapPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)

    $selectAllBtn = New-Object System.Windows.Controls.Button
    $selectAllBtn.Content = 'Select All'
    $selectAllBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $selectAllBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $btnRow.Children.Add($selectAllBtn) | Out-Null

    $clearAllBtn = New-Object System.Windows.Controls.Button
    $clearAllBtn.Content = 'Clear All'
    $clearAllBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $btnRow.Children.Add($clearAllBtn) | Out-Null

    $panel.Children.Add($btnRow) | Out-Null

    $itemsLabel = New-Object System.Windows.Controls.Label
    $itemsLabel.Content = 'ITEMS'
    $itemsLabel.FontWeight = 'Bold'
    $itemsLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $panel.Children.Add($itemsLabel) | Out-Null

    $allCheckboxes = [System.Collections.ArrayList]::new()
    $lastCategory = ''

    foreach ($item in $catalog) {
        if ($item.Category -ne $lastCategory) {
            $catLabel = New-Object System.Windows.Controls.TextBlock
            $catLabel.Text = "-- $($item.Category) --"
            $catLabel.FontSize = 12
            $catLabel.FontWeight = 'Bold'
            $catLabel.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString('#A6ADC8'))
            $catLabel.Margin = [System.Windows.Thickness]::new(0, 8, 0, 4)
            $panel.Children.Add($catLabel) | Out-Null
            $lastCategory = $item.Category
        }

        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = [System.Windows.Thickness]::new(8, 3, 0, 3)

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = " $($item.Name)"
        $cb.Tag = $item
        $cb.Foreground = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString('#CDD6F4'))
        $cb.FontSize = 13
        $cb.VerticalAlignment = 'Center'
        $row.Children.Add($cb) | Out-Null

        $panel.Children.Add($row) | Out-Null
        $allCheckboxes.Add($cb) | Out-Null
    }

    $Global:SyncHash.DebloatCheckboxes = $allCheckboxes

    $selectAllBtn.Add_Click({
        foreach ($cb in $Global:SyncHash.DebloatCheckboxes) { $cb.IsChecked = $true }
    })
    $clearAllBtn.Add_Click({
        foreach ($cb in $Global:SyncHash.DebloatCheckboxes) { $cb.IsChecked = $false }
    })

    # Spacer
    $spacer = New-Object System.Windows.Controls.Border
    $spacer.Height = 16
    $panel.Children.Add($spacer) | Out-Null

    # Run button
    $runBtn = New-Object System.Windows.Controls.Button
    $runBtn.Content = 'Run Selected'
    $runBtn.Padding = [System.Windows.Thickness]::new(24, 10, 24, 10)
    $runBtn.FontSize = 14
    $runBtn.FontWeight = 'Bold'
    $runBtn.Background = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#89B4FA'))
    $runBtn.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#1E1E2E'))
    $runBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $panel.Children.Add($runBtn) | Out-Null

    # Progress bar
    $progress = New-Object System.Windows.Controls.ProgressBar
    $progress.Height = 4
    $progress.IsIndeterminate = $false
    $progress.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $progress.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#89B4FA'))
    $progress.Background = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#2D2D44'))
    $panel.Children.Add($progress) | Out-Null

    $statusText = New-Object System.Windows.Controls.TextBlock
    $statusText.FontSize = 13
    $statusText.TextWrapping = 'Wrap'
    $statusText.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#A6ADC8'))
    $panel.Children.Add($statusText) | Out-Null

    $Global:SyncHash.DebloatRunBtn = $runBtn
    $Global:SyncHash.DebloatProgress = $progress
    $Global:SyncHash.DebloatStatusText = $statusText
    $Global:SyncHash.StatusText = $statusText

    $runBtn.Add_Click({
        $selected = @()
        foreach ($cb in $Global:SyncHash.DebloatCheckboxes) {
            if ($cb.IsChecked) { $selected += $cb.Tag }
        }

        if ($selected.Count -eq 0) {
            Write-Log 'No items selected' -Level Warning
            return
        }

        $Global:SyncHash.DebloatRunBtn.IsEnabled = $false
        $Global:SyncHash.DebloatProgress.IsIndeterminate = $true
        $Global:SyncHash.DebloatStatusText.Text = "Processing $($selected.Count) item(s)..."

        $itemList = $selected | ForEach-Object {
            @{
                Category = $_.Category; Type = $_.Type; Name = $_.Name
                AppxName = $_.AppxName; ProvisionedName = $_.ProvisionedName
                RegOps = $_.RegOps; Action = $_.Action
                ProductId = $_.ProductId; Culture = $_.Culture
            }
        }

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('SyncHash', $Global:SyncHash)
        $rs.SessionStateProxy.SetVariable('ItemList', $itemList)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $ps.AddScript({
            $toolkitRoot = $SyncHash.Toolkit.Root
            Get-ChildItem -Path "$toolkitRoot\Core" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
            Get-ChildItem -Path "$toolkitRoot\UI" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
            Get-ChildItem -Path "$toolkitRoot\Modules" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }

            $entry = @{
                Name = 'Windows-Debloat'; Label = 'Debloat & Tweaks'
                StartTime = Get-Date; EndTime = $null; Status = 'Success'; Detail = ''
            }

            $total = $ItemList.Count
            $count = 0
            $failed = 0
            $officeSelection = @()

            foreach ($item in $ItemList) {
                $count++
                Write-Log "[$count/$total] Applying $($item.Name)..." -Level Info
                Update-ActionStatus "Applying $($item.Name) ($count/$total)..." '#F9E2AF'

                try {
                    switch ($item.Type) {
                        'Appx' {
                            $userPkgs = Get-AppxPackage -AllUsers -Name $item.AppxName -ErrorAction SilentlyContinue
                            if ($userPkgs) {
                                $userPkgs | Remove-AppxPackage -AllUsers -ErrorAction Stop
                            }
                            $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                                Where-Object { $_.DisplayName -like $item.ProvisionedName }
                            if ($provisioned) {
                                $provisioned | Remove-AppxProvisionedPackage -Online -ErrorAction Stop | Out-Null
                            }
                            if (-not $userPkgs -and -not $provisioned) {
                                Write-Log "  $($item.Name) not present - skipped" -Level Info
                            } else {
                                Write-Log "  $($item.Name) removed" -Level Success
                            }
                        }
                        'Registry' {
                            foreach ($op in $item.RegOps) {
                                Set-DebloatRegistryValue -Path $op.Path -Name $op.Name -Value $op.Value -PropertyType $op.PropertyType
                            }
                            Write-Log "  $($item.Name) applied" -Level Success
                        }
                        'Action' {
                            & $item.Action | Out-Null
                            Write-Log "  $($item.Name) applied" -Level Success
                        }
                        'OfficeC2R' {
                            $officeSelection += $item
                        }
                    }
                } catch {
                    Write-Log "  $($item.Name) error: $($_.Exception.Message)" -Level Error
                    $failed++
                }
            }

            # Office C2R items are batched into a single setup.exe /configure call
            if ($officeSelection.Count -gt 0) {
                Write-Log "Removing $($officeSelection.Count) Office Click-to-Run product/language(s) in a single pass..." -Level Info
                Update-ActionStatus "Removing Office Click-to-Run selection..." '#F9E2AF'
                $odtPath = Join-Path $toolkitRoot 'CustomInstallers\ODT\setup.exe'
                $ok = Remove-OfficeC2RSelection -Selection $officeSelection -SetupExePath $odtPath
                if ($ok) {
                    Write-Log "  Office Click-to-Run selection removed" -Level Success
                } else {
                    Write-Log "  Office Click-to-Run removal failed" -Level Error
                    $failed++
                }
            }

            if ($failed -gt 0) {
                $entry.Detail = "$failed of $total failed"
                Write-Log "Debloat run complete with $failed failure(s)" -Level Warning
            } else {
                Write-Log "All $total item(s) applied successfully" -Level Success
            }

            $entry.EndTime = Get-Date
            $SyncHash.Window.Dispatcher.Invoke([action]{
                if ($SyncHash.Toolkit.Session) {
                    $SyncHash.Toolkit.Session.ModulesRun.Add($entry) | Out-Null
                }
                $SyncHash.DebloatRunBtn.IsEnabled = $true
                $SyncHash.DebloatProgress.IsIndeterminate = $false
                $SyncHash.DebloatStatusText.Text = ''
            })
        }) | Out-Null
        $ps.BeginInvoke() | Out-Null
    })

    $scroll.Content = $panel
    return $scroll
}
