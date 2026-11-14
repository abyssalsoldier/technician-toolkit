# Module: System-Repair.ps1
# Runs DISM (RestoreHealth) and SFC (/scannow) with real progress parsing and
# activity-based stall detection (log files + process CPU time), so a DISM run
# that sits at ~62% can be told apart from one that is genuinely hung.
# NOTE: keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

function Register-SystemRepair {
    @{
        Name         = 'System-Repair'
        Label        = 'System Repair'
        Description  = 'Run DISM and SFC with live progress and stall detection.'
        RequiresAuth = $false
        SortOrder    = 46
        EntryPoint   = 'Invoke-SystemRepair'
        UIDefinition = 'Get-SystemRepairUI'
    }
}

function Get-SystemRepairUI {
    # ---- Tunables ----------------------------------------------------------
    $quietAfterSeconds = 60     # no activity this long -> "Quiet" (yellow)
    $stalledAfterSeconds = 300  # no activity this long -> "Possibly stalled" (red)
    # ------------------------------------------------------------------------

    $brush = {
        param($hex)
        New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
    }

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)

    # ===== HEADER =====
    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = 'System Repair'
    $header.FontSize = 22
    $header.FontWeight = 'Bold'
    $header.Foreground = & $brush (Get-ToolkitAccent)
    $header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $panel.Children.Add($header) | Out-Null

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = 'Repair the Windows component store (DISM) and system files (SFC). Progress comes from the tools'' own output, and a separate activity monitor watches the DISM/CBS logs and process CPU so you can tell a slow step from a hung one. Requires an elevated toolkit.'
    $desc.FontSize = 13
    $desc.Foreground = & $brush '#A6ADC8'
    $desc.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)
    $desc.TextWrapping = 'Wrap'
    $panel.Children.Add($desc) | Out-Null

    # ===== DISM / SFC =====
    $sectionLabel = New-Object System.Windows.Controls.Label
    $sectionLabel.Content = 'DISM + SFC'
    $sectionLabel.FontWeight = 'Bold'
    $sectionLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $panel.Children.Add($sectionLabel) | Out-Null

    $btnRow = New-Object System.Windows.Controls.WrapPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.Margin = [System.Windows.Thickness]::new(0, 4, 0, 12)

    $mkBtn = {
        param($text)
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $text
        $b.Padding = [System.Windows.Thickness]::new(16, 6, 16, 6)
        $b.Margin = [System.Windows.Thickness]::new(0, 0, 8, 6)
        $b
    }
    $dismBtn   = & $mkBtn 'Run DISM (RestoreHealth)'
    $sfcBtn    = & $mkBtn 'Run SFC (/scannow)'
    $bothBtn   = & $mkBtn 'Run Both (DISM then SFC)'
    $bothBtn.Background = & $brush (Get-ToolkitAccent)
    $bothBtn.Foreground = & $brush '#1E1E2E'
    $bothBtn.FontWeight = 'Bold'
    $cancelBtn = & $mkBtn 'Cancel'
    $cancelBtn.IsEnabled = $false
    foreach ($b in @($bothBtn, $dismBtn, $sfcBtn, $cancelBtn)) { $btnRow.Children.Add($b) | Out-Null }
    $panel.Children.Add($btnRow) | Out-Null

    # --- Optional DISM repair source ---
    $srcDesc = New-Object System.Windows.Controls.TextBlock
    $srcDesc.Text = 'Optional DISM repair source: an install.wim or install.esd matching this Windows build (e.g. from a mounted ISO: D:\sources\install.wim). Leave blank to download repair files from Windows Update.'
    $srcDesc.FontSize = 12
    $srcDesc.Foreground = & $brush '#A6ADC8'
    $srcDesc.TextWrapping = 'Wrap'
    $srcDesc.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $panel.Children.Add($srcDesc) | Out-Null

    $srcRow = New-Object System.Windows.Controls.Grid
    $srcRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $srcRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    $srcRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::Auto }))
    $srcRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::Auto }))
    $srcRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(56) }))

    $srcBox = New-Object System.Windows.Controls.TextBox
    $srcBox.Height = 28
    $srcBox.VerticalContentAlignment = 'Center'
    $srcBox.Padding = [System.Windows.Thickness]::new(4, 0, 4, 0)
    $srcBox.ToolTip = 'Path to install.wim or install.esd (optional)'
    $srcBrowse = New-Object System.Windows.Controls.Button
    $srcBrowse.Content = 'Browse...'
    $srcBrowse.Padding = [System.Windows.Thickness]::new(12, 4, 12, 4)
    $srcBrowse.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $idxLabel = New-Object System.Windows.Controls.TextBlock
    $idxLabel.Text = 'Index:'
    $idxLabel.VerticalAlignment = 'Center'
    $idxLabel.Margin = [System.Windows.Thickness]::new(12, 0, 6, 0)
    $idxBox = New-Object System.Windows.Controls.TextBox
    $idxBox.Text = '1'
    $idxBox.Height = 28
    $idxBox.VerticalContentAlignment = 'Center'
    $idxBox.ToolTip = 'Image index inside the WIM/ESD that matches the installed edition (see: dism /Get-WimInfo /WimFile:<path>)'
    [System.Windows.Controls.Grid]::SetColumn($srcBox, 0);    $srcRow.Children.Add($srcBox) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($srcBrowse, 1); $srcRow.Children.Add($srcBrowse) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($idxLabel, 2);  $srcRow.Children.Add($idxLabel) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($idxBox, 3);    $srcRow.Children.Add($idxBox) | Out-Null
    $panel.Children.Add($srcRow) | Out-Null

    $limitChk = New-Object System.Windows.Controls.CheckBox
    $limitChk.Content = 'Limit access: do not fall back to Windows Update (only applies when a source is set)'
    $limitChk.ToolTip = 'Available once a source file is entered. With no source, DISM always uses Windows Update.'
    $limitChk.IsChecked = $true
    $limitChk.Foreground = & $brush '#CDD6F4'
    $limitChk.FontSize = 13
    $limitChk.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $panel.Children.Add($limitChk) | Out-Null

    $srcBrowse.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Windows image (install.wim;install.esd)|*.wim;*.esd|All files (*.*)|*.*'
        $dlg.Title = 'Select install.wim or install.esd'
        if ($dlg.ShowDialog() -eq $true) { $Global:SyncHash.SrSourceBox.Text = $dlg.FileName }
    }.GetNewClosure())

    $Global:SyncHash.SrSourceBox = $srcBox
    $Global:SyncHash.SrSourceBrowse = $srcBrowse
    $Global:SyncHash.SrIndexBox = $idxBox
    $Global:SyncHash.SrLimitChk = $limitChk
    # The checkbox is only meaningful (and only enabled) when a source path is entered and no run is active
    $Global:SyncHash.SrSyncLimit = {
        $sh = $Global:SyncHash
        $sh.SrLimitChk.IsEnabled = ((-not $sh.SrRunning) -and -not [string]::IsNullOrWhiteSpace($sh.SrSourceBox.Text))
    }
    $srcBox.Add_TextChanged({ & $Global:SyncHash.SrSyncLimit }.GetNewClosure())
    & $Global:SyncHash.SrSyncLimit
    if ($null -eq $Global:SyncHash.SrSourceArg) { $Global:SyncHash.SrSourceArg = $null; $Global:SyncHash.SrLimitAccess = $true }

    $stepText = New-Object System.Windows.Controls.TextBlock
    $stepText.Text = 'Idle'
    $stepText.FontSize = 14
    $stepText.FontWeight = 'Bold'
    $stepText.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $panel.Children.Add($stepText) | Out-Null

    $progress = New-Object System.Windows.Controls.ProgressBar
    $progress.Height = 14
    $progress.Minimum = 0
    $progress.Maximum = 100
    $progress.Value = 0
    $progress.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $panel.Children.Add($progress) | Out-Null

    $statusText = New-Object System.Windows.Controls.TextBlock
    $statusText.FontSize = 13
    $statusText.Foreground = & $brush '#A6ADC8'
    $statusText.TextWrapping = 'Wrap'
    $statusText.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $panel.Children.Add($statusText) | Out-Null

    $stateText = New-Object System.Windows.Controls.TextBlock
    $stateText.FontSize = 13
    $stateText.FontWeight = 'Bold'
    $stateText.TextWrapping = 'Wrap'
    $stateText.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $panel.Children.Add($stateText) | Out-Null

    $tailLabel = New-Object System.Windows.Controls.Label
    $tailLabel.Content = 'LIVE LOG ACTIVITY'
    $tailLabel.FontWeight = 'Bold'
    $tailLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $panel.Children.Add($tailLabel) | Out-Null

    $tailBox = New-Object System.Windows.Controls.TextBox
    $tailBox.IsReadOnly = $true
    $tailBox.Height = 220
    $tailBox.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $tailBox.FontSize = 12
    $tailBox.Background = & $brush '#181825'
    $tailBox.Foreground = & $brush '#CDD6F4'
    $tailBox.VerticalScrollBarVisibility = 'Auto'
    $tailBox.HorizontalScrollBarVisibility = 'Auto'
    $tailBox.TextWrapping = 'NoWrap'
    $tailBox.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $panel.Children.Add($tailBox) | Out-Null

    $resultText = New-Object System.Windows.Controls.TextBlock
    $resultText.FontSize = 13
    $resultText.TextWrapping = 'Wrap'
    $resultText.Margin = [System.Windows.Thickness]::new(0, 0, 0, 24)
    $panel.Children.Add($resultText) | Out-Null

    # ===== TEMP CLEANUP =====
    $tempLabel = New-Object System.Windows.Controls.Label
    $tempLabel.Content = 'TEMP FILES'
    $tempLabel.FontWeight = 'Bold'
    $tempLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $panel.Children.Add($tempLabel) | Out-Null

    $tempDesc = New-Object System.Windows.Controls.TextBlock
    $tempDesc.Text = 'Delete the contents of the current user''s temp folder and C:\Windows\Temp. Files that are in use are skipped, and the toolkit''s own working folders (including the exe''s extracted files) are left alone.'
    $tempDesc.FontSize = 13
    $tempDesc.Foreground = & $brush '#A6ADC8'
    $tempDesc.TextWrapping = 'Wrap'
    $tempDesc.Margin = [System.Windows.Thickness]::new(0, 4, 0, 10)
    $panel.Children.Add($tempDesc) | Out-Null

    $clearTempBtn = New-Object System.Windows.Controls.Button
    $clearTempBtn.Content = 'Clear Temp Files'
    $clearTempBtn.Padding = [System.Windows.Thickness]::new(16, 6, 16, 6)
    $clearTempBtn.HorizontalAlignment = 'Left'
    $panel.Children.Add($clearTempBtn) | Out-Null

    $tempStatus = New-Object System.Windows.Controls.TextBlock
    $tempStatus.FontSize = 13
    $tempStatus.TextWrapping = 'Wrap'
    $tempStatus.Margin = [System.Windows.Thickness]::new(0, 8, 0, 24)
    $panel.Children.Add($tempStatus) | Out-Null
    $Global:SyncHash.SrClearTempBtn = $clearTempBtn
    $Global:SyncHash.SrTempStatus = $tempStatus

    $Global:SyncHash.SrDismBtn    = $dismBtn
    $Global:SyncHash.SrSfcBtn     = $sfcBtn
    $Global:SyncHash.SrBothBtn    = $bothBtn
    $Global:SyncHash.SrCancelBtn  = $cancelBtn
    $Global:SyncHash.SrStepText   = $stepText
    $Global:SyncHash.SrProgress   = $progress
    $Global:SyncHash.SrStatusText = $statusText
    $Global:SyncHash.SrStateText  = $stateText
    $Global:SyncHash.SrTailBox    = $tailBox
    $Global:SyncHash.SrResultText = $resultText
    $Global:SyncHash.SrConfig     = @{ QuietAfter = $quietAfterSeconds; StalledAfter = $stalledAfterSeconds }
    if ($null -eq $Global:SyncHash.SrRunning) { $Global:SyncHash.SrRunning = $false }
    if ($Global:SyncHash.SrRunning) {
        # Page was rebuilt (user navigated away and back) while a run is active: reflect that state;
        # the UI timer keeps feeding these new controls.
        foreach ($b in @($dismBtn, $sfcBtn, $bothBtn, $clearTempBtn, $srcBox, $srcBrowse, $idxBox, $limitChk)) { $b.IsEnabled = $false }
        $cancelBtn.IsEnabled = $true
        $Global:SyncHash.SrAppliedTailVer = 0
    } else {
        $Global:SyncHash.SrCancel = $false
    }

    # Click handlers can't reliably resolve module-scope functions by name (the module files are
    # dot-sourced inside the GUI init, and handlers run later), so stash the starter's scriptblock
    # on SyncHash while we're still in a scope that can see it.
    $Global:SyncHash.SrStart = (Get-Command -Name Start-SystemRepairRun -CommandType Function).ScriptBlock

    $clearTempBtn.Add_Click({
        $answer = [System.Windows.MessageBox]::Show(
            "Delete all files in your user temp folder and C:\Windows\Temp?`n`nFiles in use are skipped. This cannot be undone.",
            'Clear Temp Files', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }

        $Global:SyncHash.SrClearTempBtn.IsEnabled = $false
        $Global:SyncHash.SrTempStatus.Text = 'Clearing temp files...'
        $Global:SyncHash.SrTempStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString('#A6ADC8'))

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('SyncHash', $Global:SyncHash)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $ps.AddScript({
            $toolkitRoot = $SyncHash.Toolkit.Root
            Get-ChildItem -Path "$toolkitRoot\Core" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
            Get-ChildItem -Path "$toolkitRoot\UI" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }

            $entry = @{
                Name = 'Clear-TempFiles'; Label = 'Clear Temp Files'
                StartTime = Get-Date; EndTime = $null; Status = 'Success'; Detail = ''
            }
            $msg = ''; $color = '#A6E3A1'
            try {
                $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)

                $targets = @((Get-Item -LiteralPath $env:TEMP -ErrorAction Stop).FullName)
                if ($isAdmin) { $targets += (Join-Path $env:windir 'Temp') }

                # Never delete the toolkit's own working copy (it runs from a temp folder when launched from USB)
                $protected = @($SyncHash.Toolkit.Parent, $SyncHash.Toolkit.Root) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

                $deleted = 0; $skipped = 0; $freed = 0L
                foreach ($target in $targets) {
                    if (-not (Test-Path -LiteralPath $target)) { continue }
                    Write-Log "Clear Temp: cleaning $target" -Level Info
                    foreach ($item in (Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)) {
                        $full = $item.FullName.TrimEnd('\')
                        $isProtected = $false
                        foreach ($p in $protected) {
                            if ($p -eq $full -or $p -like "$full\*") { $isProtected = $true; break }
                        }
                        # EndpointToolkit_* = toolkit working copy and logs; IXP*.TMP = the running exe's IExpress payload
                        if ($isProtected -or $item.Name -like 'EndpointToolkit_*' -or $item.Name -like 'IXP*.TMP') { continue }
                        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped++; continue }   # don't follow links/junctions

                        $before = 0L
                        if ($item.PSIsContainer) {
                            $before = [long](Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                        } else { $before = $item.Length }

                        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue

                        if (Test-Path -LiteralPath $full) {
                            $skipped++
                            $after = 0L
                            if ($item.PSIsContainer) {
                                $after = [long](Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                            } else { $after = $before }
                            $freed += [math]::Max(0, $before - $after)
                        } else {
                            $deleted++
                            $freed += $before
                        }
                    }
                }

                $freedText = if ($freed -ge 1GB) { '{0:N2} GB' -f ($freed / 1GB) } else { '{0:N1} MB' -f ($freed / 1MB) }
                $msg = "Removed $deleted item(s), freed $freedText. $skipped item(s) skipped (in use or protected)."
                if (-not $isAdmin) { $msg += ' C:\Windows\Temp was not cleaned (toolkit is not elevated).'; $color = '#F9E2AF' }
                $entry.Detail = $msg
                Write-Log "Clear Temp: $msg" -Level Success
            } catch {
                $msg = "Failed to clear temp files: $($_.Exception.Message)"
                $color = '#F38BA8'
                $entry.Status = 'Error'; $entry.Detail = $msg
                Write-Log "Clear Temp: $msg" -Level Error
            } finally {
                $entry.EndTime = Get-Date
                $SyncHash.SrTempFinal = @{ Text = $msg; Color = $color }
                $SyncHash.Window.Dispatcher.Invoke([action]{
                    $f = $SyncHash.SrTempFinal
                    $SyncHash.SrTempStatus.Text = $f.Text
                    $SyncHash.SrTempStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                        [System.Windows.Media.ColorConverter]::ConvertFromString($f.Color))
                    $SyncHash.SrClearTempBtn.IsEnabled = (-not $SyncHash.SrRunning)
                    if ($SyncHash.Toolkit.Session) { $SyncHash.Toolkit.Session.ModulesRun.Add($entry) | Out-Null }
                })
            }
        }) | Out-Null
        $ps.BeginInvoke() | Out-Null
    }.GetNewClosure())

    $runHandler = {
        param($steps)
        try {
            & $Global:SyncHash.SrStart -Steps $steps
        } catch {
            $Global:SyncHash.SrRunning = $false
            $Global:SyncHash.SrResultText.Text = "Failed to start: $($_.Exception.Message)"
            $Global:SyncHash.SrResultText.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString('#F38BA8'))
            foreach ($n in 'SrDismBtn', 'SrSfcBtn', 'SrBothBtn', 'SrClearTempBtn', 'SrSourceBox', 'SrSourceBrowse', 'SrIndexBox') { $Global:SyncHash[$n].IsEnabled = $true }
            & $Global:SyncHash.SrSyncLimit
            $Global:SyncHash.SrCancelBtn.IsEnabled = $false
            Write-Log "System Repair: failed to start - $($_.Exception.Message)" -Level Error
        }
    }.GetNewClosure()
    $dismBtn.Add_Click({ & $runHandler @('DISM') }.GetNewClosure())
    $sfcBtn.Add_Click({ & $runHandler @('SFC') }.GetNewClosure())
    $bothBtn.Add_Click({ & $runHandler @('DISM', 'SFC') }.GetNewClosure())
    $cancelBtn.Add_Click({
        $Global:SyncHash.SrCancel = $true
        $Global:SyncHash.SrCancelBtn.IsEnabled = $false
        $Global:SyncHash.SrStateText.Text = 'Cancelling...'
        Write-Log 'System Repair: cancel requested by user.' -Level Warning
    }.GetNewClosure())

    $scroll.Content = $panel
    return $scroll
}

function Start-SystemRepairRun {
    param([string[]]$Steps)

    if ($Global:SyncHash.SrRunning) { return }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $Global:SyncHash.SrResultText.Text = 'DISM and SFC require an elevated session. Restart the toolkit as Administrator.'
        $Global:SyncHash.SrResultText.Foreground = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString('#F38BA8'))
        Write-Log 'System Repair: not running elevated; aborted.' -Level Error
        return
    }

    # Validate and build the optional DISM source ("wim:<path>:<index>" / "esd:<path>:<index>")
    $Global:SyncHash.SrSourceArg = $null
    $Global:SyncHash.SrLimitAccess = [bool]$Global:SyncHash.SrLimitChk.IsChecked
    $srcPath = $Global:SyncHash.SrSourceBox.Text.Trim().Trim('"')
    if ($Steps -contains 'DISM' -and $srcPath) {
        $srcErr = $null
        $ext = [System.IO.Path]::GetExtension($srcPath).ToLowerInvariant()
        $idx = 0
        if (-not (Test-Path -LiteralPath $srcPath -PathType Leaf)) { $srcErr = "Source file not found: $srcPath" }
        elseif ($ext -notin '.wim', '.esd') { $srcErr = 'Source must be an install.wim or install.esd file (mount an ISO and pick sources\install.wim).' }
        elseif (-not [int]::TryParse($Global:SyncHash.SrIndexBox.Text.Trim(), [ref]$idx) -or $idx -lt 1) { $srcErr = 'Index must be a number 1 or higher.' }
        if ($srcErr) {
            $Global:SyncHash.SrResultText.Text = $srcErr
            $Global:SyncHash.SrResultText.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString('#F38BA8'))
            return
        }
        $Global:SyncHash.SrSourceArg = "$($ext.TrimStart('.')):${srcPath}:$idx"
    }

    $Global:SyncHash.SrRunning = $true
    $Global:SyncHash.SrCancel = $false
    foreach ($n in 'SrDismBtn', 'SrSfcBtn', 'SrBothBtn', 'SrClearTempBtn', 'SrSourceBox', 'SrSourceBrowse', 'SrIndexBox', 'SrLimitChk') { $Global:SyncHash[$n].IsEnabled = $false }
    $Global:SyncHash.SrCancelBtn.IsEnabled = $true
    $Global:SyncHash.SrResultText.Text = ''
    $Global:SyncHash.SrTailBox.Text = ''
    $Global:SyncHash.SrProgress.Value = 0

    $Global:SyncHash.SrUi = [hashtable]::Synchronized(@{ TailVer = 0 })
    $Global:SyncHash.SrEntries = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $Global:SyncHash.SrFinal = $null
    $Global:SyncHash.SrDone = $false
    $Global:SyncHash.SrAppliedTailVer = 0

    # UI-thread timer: applies worker state to the controls (same pattern as the time-zone preview timer)
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $Global:SyncHash.SrTimer = $timer
    $timer.Add_Tick({
        try {
            $sh = $Global:SyncHash
            $u = $sh.SrUi
            $mk = { param($hex) New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }

            if ($u.ContainsKey('Step'))   { $sh.SrStepText.Text = [string]$u['Step'] }
            if ($u.ContainsKey('Pct'))    { $sh.SrProgress.Value = [double]$u['Pct'] }
            if ($u.ContainsKey('Status')) { $sh.SrStatusText.Text = [string]$u['Status'] }
            if ($u.ContainsKey('State')) {
                $sh.SrStateText.Text = [string]$u['State']
                $sh.SrStateText.Foreground = & $mk $u['StateColor']
            }
            if ($u['TailVer'] -ne $sh.SrAppliedTailVer -and $u.ContainsKey('Tail')) {
                $sh.SrAppliedTailVer = $u['TailVer']
                $sh.SrTailBox.Text = [string]$u['Tail']
                $sh.SrTailBox.CaretIndex = $sh.SrTailBox.Text.Length
                $sh.SrTailBox.ScrollToEnd()
            }

            if ($sh.Toolkit.Session) {
                while ($sh.SrEntries.Count -gt 0) {
                    $e = $sh.SrEntries[0]; $sh.SrEntries.RemoveAt(0)
                    $sh.Toolkit.Session.ModulesRun.Add($e) | Out-Null
                }
            }

            if ($sh.SrDone) {
                $sh.SrTimer.Stop()
                $f = $sh.SrFinal
                if ($f) {
                    $sh.SrResultText.Text = $f.Text
                    $sh.SrResultText.Foreground = & $mk $f.Color
                }
                $sh.SrStateText.Text = ''
                $sh.SrStepText.Text = 'Idle'
                foreach ($n in 'SrDismBtn', 'SrSfcBtn', 'SrBothBtn', 'SrClearTempBtn', 'SrSourceBox', 'SrSourceBrowse', 'SrIndexBox') { $sh[$n].IsEnabled = $true }
                $sh.SrCancelBtn.IsEnabled = $false
                $sh.SrRunning = $false
                $sh.SrCancel = $false
                & $sh.SrSyncLimit
            }
        } catch {
            Write-Log "System Repair: UI update error - $($_.Exception.Message)" -Level Error
        }
    })
    $timer.Start()

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('SyncHash', $Global:SyncHash)
    $rs.SessionStateProxy.SetVariable('RunSteps', $Steps)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript({
        $toolkitRoot = $SyncHash.Toolkit.Root
        Get-ChildItem -Path "$toolkitRoot\Core" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
        Get-ChildItem -Path "$toolkitRoot\UI" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }

        $cfg = $SyncHash.SrConfig
        $sysDir = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { "$env:windir\Sysnative" } else { "$env:windir\System32" }
        $cbsLog = Join-Path $env:windir 'Logs\CBS\CBS.log'
        $runDir = Join-Path $env:TEMP 'EndpointToolkit_SystemRepair'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null

        # ---- UI push: state goes through SyncHash, applied on the UI thread ----
        # The worker only writes plain data into SyncHash.SrUi; a DispatcherTimer on the UI thread
        # (created in Start-SystemRepairRun) reads it and updates the controls. No cross-thread
        # delegates are used for progress updates.
        function Push-Ui {
            param([hashtable]$State)
            foreach ($k in $State.Keys) { $SyncHash.SrUi[$k] = $State[$k] }
            if ($State.ContainsKey('Tail')) { $SyncHash.SrUi['TailVer'] = 1 + [int]$SyncHash.SrUi['TailVer'] }
        }

        function Read-NewLines {
            param([string]$Path, [hashtable]$Tracker)
            $lines = @()
            try {
                if (-not (Test-Path -LiteralPath $Path)) { return $lines }
                $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
                try {
                    if ($Tracker.Offset -gt $fs.Length) { $Tracker.Offset = 0 }
                    $fs.Seek($Tracker.Offset, 'Begin') | Out-Null
                    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                    $text = $sr.ReadToEnd()
                    $Tracker.Offset = $fs.Position
                    if ($text) { $lines = $text -split "`r?`n" | Where-Object { $_ } }
                } finally { $fs.Dispose() }
            } catch { }
            return $lines
        }

        function Get-FileSignature {
            param([string]$Path)
            try {
                $fi = New-Object System.IO.FileInfo($Path)
                if ($fi.Exists) { return "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)" }
            } catch { }
            return ''
        }

        function Get-CpuSignature {
            $total = 0L
            try {
                foreach ($p in (Get-Process -Name 'dism', 'DismHost', 'TiWorker', 'TrustedInstaller', 'sfc' -ErrorAction SilentlyContinue)) {
                    try { $total += $p.TotalProcessorTime.Ticks } catch { }
                }
            } catch { }
            return "$total"
        }

        function Stop-ProcessAndChildren {
            param($Proc)
            try {
                # One-time lookup at cancel (not polled)
                $kids = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$($Proc.Id)" -ErrorAction SilentlyContinue
                foreach ($k in $kids) { Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue }
            } catch { }
            try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch { }
        }

        function Format-Span { param([TimeSpan]$t) '{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds }

        function Invoke-RepairStep {
            param([string]$Name, [int]$Index, [int]$Count)

            $isDism = ($Name -eq 'DISM')
            $title = if ($isDism) { 'DISM RestoreHealth' } else { 'SFC /scannow' }
            $stepLabel = "Step $Index of $Count - $title"
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $dismLog = Join-Path $runDir "dism_$stamp.log"

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            if ($isDism) {
                $psi.FileName = "$sysDir\dism.exe"
                $psi.Arguments = "/Online /Cleanup-Image /RestoreHealth /NoRestart /LogPath:`"$dismLog`""
            } else {
                $psi.FileName = "$sysDir\sfc.exe"
                $psi.Arguments = '/scannow'
                $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode   # sfc writes UTF-16
            }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.CreateNoWindow = $true

            $result = @{ Name = $Name; Status = 'Success'; Detail = ''; RebootNeeded = $false }
            $started = Get-Date

            Write-Log "System Repair: starting $title." -Level Info
            Push-Ui @{ Step = $stepLabel; Pct = 0; Status = 'Starting...'; State = 'Starting'; StateColor = '#A6ADC8'; Tail = '' }

            # DISM is driven through the Dism module's Repair-WindowsImage cmdlet, not dism.exe:
            # dism.exe block-buffers its output when redirected to a pipe, so the progress bar never
            # reaches us until it exits. The cmdlet reports real progress via PowerShell progress records.
            # SFC still runs as a process (its output is read from the redirected stream).
            $useCmdlet = $isDism
            $proc = $null
            $inner = $null
            $async = $null
            try {
                if ($useCmdlet) {
                    $inner = [powershell]::Create()
                    $inner.AddScript({
                        param($log, $source, $limit)
                        Import-Module Dism -ErrorAction Stop
                        $p = @{ Online = $true; RestoreHealth = $true; NoRestart = $true; LogPath = $log; ErrorAction = 'Stop' }
                        if ($source) { $p.Source = $source; if ($limit) { $p.LimitAccess = $true } }
                        Repair-WindowsImage @p
                    }).AddArgument($dismLog).AddArgument($SyncHash.SrSourceArg).AddArgument([bool]$SyncHash.SrLimitAccess) | Out-Null
                    if ($SyncHash.SrSourceArg) { Write-Log "System Repair: DISM source = $($SyncHash.SrSourceArg) (limit access: $($SyncHash.SrLimitAccess))." -Level Info }
                    $async = $inner.BeginInvoke()
                } else {
                    $proc = [System.Diagnostics.Process]::Start($psi)
                }
            } catch {
                $result.Status = 'Error'
                $result.Detail = "Could not start ${title}: $($_.Exception.Message)"
                return $result
            }
            $lastCpuChange = [datetime]::MinValue
            $phase = ''; $corrupt = -1
            $dlPct = -1; $dlMax = -1; $dlRestarts = 0; $expPct = -1; $progText = ''; $lastProgText = ''
            $aliveText = 'none'

            # Tail trackers: DISM tails its own log from the start; SFC tails [SR] lines of CBS.log from now.
            $cbsStart = 0L
            try { $cbsStart = (New-Object System.IO.FileInfo($cbsLog)).Length } catch { }
            $dismTracker = @{ Offset = 0L }
            $cbsTracker  = @{ Offset = $cbsStart }
            $tailLines = New-Object 'System.Collections.Generic.List[string]'

            $output = New-Object 'System.Collections.Generic.List[string]'
            $pct = 0.0
            $tailDirty = $false
            $lastLoggedBucket = -1
            $lastChange = Get-Date
            $lastSource = 'start'
            $sigDism = ''; $sigCbs = ''; $sigCpu = ''
            $lastSample = [datetime]::MinValue
            $exitedAt = $null
            $readTask = $null
            if ($proc) { $readTask = $proc.StandardOutput.ReadLineAsync() }

            while ($true) {
                if ($SyncHash.SrCancel) {
                    if ($useCmdlet) {
                        try { $inner.BeginStop($null, $null) | Out-Null } catch { }
                        $stopWait = Get-Date
                        while ($inner.InvocationStateInfo.State -notin 'Stopped', 'Completed', 'Failed' -and ((Get-Date) - $stopWait).TotalSeconds -lt 15) { Start-Sleep -Milliseconds 250 }
                        # Make sure the DISM host process the cmdlet started doesn't keep running
                        Get-Process -Name 'DismHost' -ErrorAction SilentlyContinue | Where-Object { try { $_.StartTime -ge $started } catch { $false } } | Stop-Process -Force -ErrorAction SilentlyContinue
                    } else {
                        Stop-ProcessAndChildren -Proc $proc
                    }
                    $result.Status = 'Cancelled'
                    $result.Detail = "Cancelled by user at $([math]::Round($pct,1))%."
                    Write-Log "System Repair: $title cancelled by user." -Level Warning
                    break
                }

                # Drain any completed stdout lines (\r-terminated progress redraws count as lines)
                while ($readTask -and $readTask.IsCompleted) {
                    $line = $null
                    try { $line = $readTask.Result } catch { }
                    if ($null -eq $line) { $readTask = $null; break }
                    $line = ($line -replace "`0", '').Trim()
                    if ($line) {
                        if ($line -match '(\d{1,3}(?:\.\d+)?)\s*%') {
                            $newPct = [double]$Matches[1]
                            if ($newPct -ge 0 -and $newPct -le 100 -and $newPct -ne $pct) {
                                if ([int]$newPct -ne [int]$pct) { $tailLines.Add("[$Name output] $line"); $tailDirty = $true }
                                $pct = $newPct
                                $lastChange = Get-Date; $lastSource = 'progress output'
                                $bucket = [int][math]::Floor($pct / 10)
                                if ($bucket -gt $lastLoggedBucket) {
                                    $lastLoggedBucket = $bucket
                                    Write-Log "System Repair: $title at $([math]::Round($pct,1))%." -Level Info
                                }
                            }
                        } else {
                            if ($output.Count -lt 500) { $output.Add($line) }
                            $tailLines.Add("[$Name output] $line"); $tailDirty = $true
                        }
                    }
                    $readTask = $proc.StandardOutput.ReadLineAsync()
                }

                if ($useCmdlet) {
                    # Real DISM progress from the cmdlet's progress records
                    try {
                        $recs = $inner.Streams.Progress
                        if ($recs.Count -gt 0) {
                            $lastRec = $recs[$recs.Count - 1]
                            $progText = (@($lastRec.Activity, $lastRec.StatusDescription, $lastRec.CurrentOperation) | Where-Object { $_ }) -join ' - '
                            $curPct = [double]$lastRec.PercentComplete
                            if ($curPct -ge 0 -and $curPct -le 100 -and $curPct -ne $pct) {
                                $pct = $curPct
                                $lastChange = Get-Date; $lastSource = 'DISM progress'
                                $bucket = [int][math]::Floor($pct / 10)
                                if ($bucket -gt $lastLoggedBucket) {
                                    $lastLoggedBucket = $bucket
                                    Write-Log "System Repair: $title at $([math]::Round($pct,1))%." -Level Info
                                }
                            }
                        }
                    } catch { }
                    if ($async.IsCompleted) { break }
                } elseif ($proc.HasExited) {
                    if (-not $exitedAt) { $exitedAt = Get-Date }
                    if (-not $readTask -or ((Get-Date) - $exitedAt).TotalSeconds -gt 5) { break }
                }

                # Sample activity signals roughly once a second
                $now = Get-Date
                if (($now - $lastSample).TotalMilliseconds -ge 1000) {
                    $lastSample = $now

                    # "Progress" (resets the stall timer) is only: DISM/SFC percent rising, DISM's own log
                    # changing, repair/verification lines in CBS.log, or a Windows Update download that
                    # advances or completes. Raw CBS.log growth and CPU use do NOT count - a download that
                    # keeps retrying writes to CBS.log constantly while getting nowhere. They are shown
                    # separately as "alive" signals.
                    $nd = Get-FileSignature $dismLog
                    $nc = Get-FileSignature $cbsLog
                    $np = Get-CpuSignature
                    if ($isDism -and $nd -ne $sigDism) { $lastChange = $now; $lastSource = 'DISM log' }
                    $alive = @()
                    if ($nc -ne $sigCbs) { $alive += 'CBS log' }
                    if ($np -ne $sigCpu) { $alive += 'CPU'; $lastCpuChange = $now }
                    $aliveText = if ($alive) { $alive -join ' + ' } else { 'none' }
                    $sigDism = $nd; $sigCbs = $nc; $sigCpu = $np

                    # DISM's own log goes quiet during the heavy phase (the work is logged in CBS.log),
                    # so DISM shows both logs; SFC shows only its [SR] lines from CBS.log.
                    $newLines = if ($isDism) {
                        @(Read-NewLines -Path $dismLog -Tracker $dismTracker) + @(Read-NewLines -Path $cbsLog -Tracker $cbsTracker)
                    } else {
                        Read-NewLines -Path $cbsLog -Tracker $cbsTracker | Where-Object { $_ -match '\[SR\]' }
                    }
                    $newLines = @($newLines | Select-Object -Last 200)
                    $tailChanged = $tailDirty
                    $tailDirty = $false
                    foreach ($l in $newLines) {
                        # Windows Update download progress DISM triggers when it has to fetch repair files
                        if ($l -match 'WULib DownloadProgress:\s*\[(\d+)\s*/\s*100\]') {
                            $v = [int]$Matches[1]
                            if ($v -ge 100 -and $dlPct -lt 100) {
                                $lastChange = $now; $lastSource = 'download completed'
                            } elseif ($v -gt $dlMax) {
                                $lastChange = $now; $lastSource = 'download advancing'
                            }
                            if ($v -lt $dlPct) { $dlMax = $v; $dlRestarts++ }   # restarted: no credit
                            elseif ($v -gt $dlMax) { $dlMax = $v }
                            $dlPct = $v
                        } elseif ($l -match 'FLOW: Entering stage:\s*(\w+)') {
                            # The servicing stack's own stage machine: the most reliable "where are we" signal
                            $stage = $Matches[1]
                            $phase = switch ($stage) {
                                'CheckCsi'            { 'Scanning component store' }
                                'CheckCbs'            { 'Verifying package store' }
                                'CheckStagedPackages' { 'Checking staged packages' }
                                'Download'            { 'Acquiring repair files' }
                                'RepairCbs'           { 'Repairing packages' }
                                'RepairCsi'           { 'Repairing component store' }
                                default               { $stage }
                            }
                            $lastChange = $now; $lastSource = "stage: $phase"
                            if ($stage -eq 'Download') { $dlPct = -1; $dlMax = -1 }   # new download round
                            Write-Log "System Repair: DISM stage - $phase$(if ($corrupt -ge 0) { " ($corrupt corrupt file(s) found by last scan)" })." -Level Info
                        } elseif ($l -match 'Corruption detection complete\.\s*numCorruptions\s*=\s*(\d+)') {
                            $corrupt = [int]$Matches[1]
                            $lastChange = $now; $lastSource = 'scan result'
                            Write-Log "System Repair: scan found $corrupt corrupt file(s)." -Level Info
                        } elseif ($l -match 'ProgressHandler: Progress \[(\d+)\].*Overall Progress \[(\d+)\]') {
                            # Package expansion (DPX) after a download or when using a Source
                            $ov = [int]$Matches[2]
                            if ($ov -ne $expPct) { $lastChange = $now; $lastSource = 'expanding package' }
                            $expPct = $ov
                        } elseif ($l -match 'Expanding package:|Started DPX phase|Ended DPX phase') {
                            $lastChange = $now; $lastSource = 'expanding package'
                        } elseif ($l -match '\bRepr:' ) {
                            $lastChange = $now; $lastSource = 'repairing files'
                        } elseif ($l -match 'CSI\s+[0-9a-f]{8}\s+Direct SIL provider') {
                            $lastChange = $now; $lastSource = 'verifying component store'
                        } elseif (-not $isDism -and $l -match '\[SR\]') {
                            $lastChange = $now; $lastSource = 'SFC verification'
                        }
                        $tailLines.Add($l); $tailChanged = $true
                        if ($tailLines.Count -gt 200) { $tailLines.RemoveAt(0) }
                    }

                    while ($tailLines.Count -gt 200) { $tailLines.RemoveAt(0) }

                    $idle = ($now - $lastChange).TotalSeconds
                    $idleText = "$([int][math]::Floor($idle / 60))m $([int]($idle % 60))s"
                    $dlStuck = ($isDism -and $dlPct -ge 0 -and $dlPct -lt 100)
                    # Silent CPU-bound phases (e.g. hashing the component store) log nothing for minutes:
                    # while the servicing processes are burning CPU, allow 3x longer before going red.
                    # A stuck download is never given that extra time.
                    $stalledLimit = $cfg.StalledAfter
                    if (-not $dlStuck -and ($now - $lastCpuChange).TotalSeconds -lt 30) { $stalledLimit = $cfg.StalledAfter * 3 }
                    if ($idle -lt $cfg.QuietAfter) {
                        $state = 'Active - making progress'; $color = '#A6E3A1'
                    } elseif ($idle -lt $stalledLimit) {
                        $state = if ($dlStuck) { "Waiting - Windows Update download at $dlPct% with no advance for $idleText. Log activity: $aliveText." }
                                 else { "Quiet - no measurable progress for $idleText (log activity: $aliveText). Still waiting." }
                        $color = '#F9E2AF'
                    } else {
                        $state = if ($dlStuck) { "Likely stuck - the Windows Update download has not completed or advanced (stuck at $dlPct%, $dlRestarts restart(s)) for $idleText. The log is busy retrying. Cancel and use a Source (install.wim/esd), or check the WSUS / Windows Update policy." }
                                 else { "Possibly stalled - no measurable progress for $idleText (log activity: $aliveText). Consider Cancel and retry." }
                        $color = '#F38BA8'
                    }
                    $status = "Elapsed $(Format-Span ($now - $started))   |   Last progress: $([int]$idle)s ago ($lastSource)   |   DISM-reported: $([math]::Round($pct,1))%"
                    if ($isDism -and $phase) {
                        $status = "Phase: $phase" + $(if ($corrupt -ge 0) { " - last scan found $corrupt corrupt file(s)" } else { '' }) + "`r`n" + $status
                    }
                    if ($isDism -and $dlPct -ge 0) { $status += "   |   Windows Update download: $dlPct%" }
                    if ($isDism -and $expPct -ge 0) { $status += "   |   Package unpack: $expPct%" }
                    if ($useCmdlet -and $progText) {
                        $status += "   |   DISM says: $progText"
                        if ($progText -ne $lastProgText) { $lastProgText = $progText; Write-Log "System Repair: DISM progress record - $progText ($([math]::Round($pct,1))%)" -Level Info }
                    }

                    $ui = @{ Step = $stepLabel; Pct = $pct; Status = $status; State = $state; StateColor = $color }
                    if ($tailChanged) { $ui.Tail = ($tailLines -join "`r`n") }
                    Push-Ui $ui
                }

                Start-Sleep -Milliseconds 250
            }

            if ($result.Status -eq 'Cancelled') { return $result }

            $code = 0
            if (-not $useCmdlet) {
                try { $proc.WaitForExit(2000) | Out-Null } catch { }
                $code = $proc.ExitCode
            }
            $text = ($output -join "`n")
            $lastMsg = ($output | Select-Object -Last 3) -join ' '

            if ($isDism) {
                $img = $null; $errMsg = $null
                try { $img = $inner.EndInvoke($async) } catch { $errMsg = $_.Exception.InnerException.Message; if (-not $errMsg) { $errMsg = $_.Exception.Message } }
                if (-not $errMsg -and $inner.Streams.Error.Count -gt 0) { $errMsg = $inner.Streams.Error[0].ToString() }
                try { $inner.Dispose() } catch { }
                if ($errMsg) {
                    $result.Status = 'Error'; $result.Detail = "DISM failed: $errMsg"
                } elseif ($img -and ($img | Select-Object -First 1).RestartNeeded) {
                    $result.Detail = 'DISM completed; a reboot is required.'; $result.RebootNeeded = $true
                } else {
                    $result.Detail = 'DISM completed successfully.'
                }
            } else {
                if     ($text -match 'did not find any integrity violations')               { $result.Detail = 'SFC found no integrity violations.' }
                elseif ($text -match 'found corrupt files and successfully repaired')       { $result.Detail = 'SFC found and repaired corrupt files (see CBS.log).'; $result.RebootNeeded = $true }
                elseif ($text -match 'found corrupt files but was unable to fix')           { $result.Status = 'Error'; $result.Detail = 'SFC found corrupt files it could not repair. Run DISM, then SFC again. Details: CBS.log ([SR] lines).' }
                elseif ($text -match 'pending which requires reboot|requires reboot')       { $result.Status = 'Error'; $result.Detail = 'A system repair is pending; reboot and run SFC again.' }
                elseif ($code -eq 0)                                                        { $result.Detail = 'SFC completed.' }
                else                                                                        { $result.Status = 'Error'; $result.Detail = "SFC exit code $code. $lastMsg" }
            }
            if ($result.Status -eq 'Success') { Push-Ui @{ Pct = 100 } }
            $lvl = if ($result.Status -eq 'Success') { 'Success' } else { 'Error' }
            Write-Log "System Repair: $title finished - $($result.Detail)" -Level $lvl
            return $result
        }

        # ---- Main sequence ----
        $results = @()
        try {
            $count = $RunSteps.Count
            $i = 0
            foreach ($stepName in $RunSteps) {
                $i++
                $entry = @{
                    Name = "Run-$stepName"; Label = "Run $stepName"
                    StartTime = Get-Date; EndTime = $null; Status = 'Success'; Detail = ''
                }
                $r = Invoke-RepairStep -Name $stepName -Index $i -Count $count
                $entry.EndTime = Get-Date
                $entry.Status = $r.Status
                $entry.Detail = $r.Detail
                $results += $r
                $SyncHash.SrEntries.Add($entry) | Out-Null   # UI timer moves these into the session log
                if ($r.Status -ne 'Success') { break }   # don't run SFC after a failed/cancelled DISM
            }
        } catch {
            Write-Log "System Repair: unexpected error - $($_.Exception.Message)" -Level Error
            $results += @{ Name = 'Error'; Status = 'Error'; Detail = $_.Exception.Message; RebootNeeded = $false }
        } finally {
            $failed = $results | Where-Object { $_.Status -ne 'Success' } | Select-Object -First 1
            $reboot = [bool]($results | Where-Object { $_.RebootNeeded })
            $summary = ($results | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '  '
            if ($failed) {
                $color = if ($failed.Status -eq 'Cancelled') { '#F9E2AF' } else { '#F38BA8' }
            } else {
                $color = '#A6E3A1'
                if ($reboot) { $summary += '  A reboot is recommended.' }
            }
            $SyncHash.SrFinal = @{ Text = $summary; Color = $color }
            $SyncHash.SrDone = $true   # UI timer applies the final state and stops itself
        }
    }) | Out-Null
    $ps.BeginInvoke() | Out-Null
}

function Invoke-SystemRepair {
    Write-Log 'System Repair module invoked.' -Level Info
}
