# Core: UsbDetection.ps1
# USB drive detection and self-update mechanism

function ConvertTo-RobocopyPathArg {
    param([string]$Path)
    # A path ending in "\" placed right before the closing quote is parsed by
    # Win32 argv rules as an escaped quote, not a literal backslash — this
    # merges the rest of the command line into the path (breaks on drive roots
    # like "D:\"). Doubling the trailing backslash keeps it literal.
    if ($Path.EndsWith('\')) {
        return '"' + $Path + '\"'
    }
    return '"' + $Path + '"'
}

function Copy-ToolkitToLocal {
    # Copies the toolkit to a local folder while showing a progress window.
    # Returns $null on success, or an error string on failure.
    param(
        [string]$Source,
        [string]$Destination
    )

    Add-Type -AssemblyName PresentationFramework

    $win = New-Object System.Windows.Window
    $win.Title = Get-ToolkitProductName
    $win.Width = 420; $win.Height = 150
    $win.WindowStartupLocation = 'CenterScreen'
    $win.ResizeMode = 'NoResize'
    $win.Topmost = $true
    $win.Background = [System.Windows.Media.Brushes]::Black

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = [System.Windows.Thickness]::new(20)
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = 'Preparing toolkit from USB...'
    $title.FontSize = 16; $title.Foreground = [System.Windows.Media.Brushes]::White
    $title.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $detail = New-Object System.Windows.Controls.TextBlock
    $detail.Text = 'Copying files locally so the USB can be removed afterwards. Please wait.'
    $detail.Foreground = [System.Windows.Media.Brushes]::LightGray
    $detail.TextWrapping = 'Wrap'
    $detail.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $bar = New-Object System.Windows.Controls.ProgressBar
    $bar.Height = 14; $bar.IsIndeterminate = $true
    $stack.Children.Add($title) | Out-Null
    $stack.Children.Add($detail) | Out-Null
    $stack.Children.Add($bar) | Out-Null
    $win.Content = $stack
    $win.Show()

    $pump = {
        $win.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    }
    & $pump

    $excludes = @('/XD', '.git', '.github', '.claude', '.vscode', '_builds', 'System Volume Information', '$RECYCLE.BIN')
    $srcArg = ConvertTo-RobocopyPathArg $Source
    $dstArg = ConvertTo-RobocopyPathArg $Destination

    # Total size (best effort) from a robocopy dry run
    $totalBytes = 0
    try {
        $dry = & robocopy.exe $Source $Destination /L /E /BYTES /NJH /NFL /NDL /NP @excludes 2>$null
        $line = $dry | Where-Object { $_ -match '^\s*Bytes\s*:\s*(\d+)' } | Select-Object -First 1
        if ($line -match '^\s*Bytes\s*:\s*(\d+)') { $totalBytes = [int64]$Matches[1] }
    } catch { }
    & $pump

    # Start-Process does not quote array elements, so names with spaces must be quoted here
    $quotedExcludes = $excludes | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $logPath = Join-Path $env:TEMP 'toolkit-local-copy.log'
    $copyArgs = @($srcArg, $dstArg, '/E') + $quotedExcludes + @('/XJ', '/NP', '/R:1', '/W:1', "/LOG:`"$logPath`"")
    $proc = Start-Process robocopy -ArgumentList $copyArgs -PassThru -WindowStyle Hidden

    $lastCheck = [datetime]::MinValue
    while (-not $proc.HasExited) {
        if (((Get-Date) - $lastCheck).TotalMilliseconds -ge 750) {
            $lastCheck = Get-Date
            $copied = (Get-ChildItem -Path $Destination -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($totalBytes -gt 0 -and $copied -ne $null) {
                $bar.IsIndeterminate = $false
                $bar.Maximum = $totalBytes
                $bar.Value = [Math]::Min($copied, $totalBytes)
                $detail.Text = "Copied {0:N0} of {1:N0} MB. Keep the USB connected until the toolkit opens." -f ($copied / 1MB), ($totalBytes / 1MB)
            }
        }
        & $pump
        Start-Sleep -Milliseconds 100
    }
    $proc.WaitForExit()
    $exit = $proc.ExitCode
    $win.Close()

    if ($exit -ge 8) {
        $errLines = @()
        if (Test-Path $logPath) {
            $errLines = @(Select-String -Path $logPath -Pattern 'ERROR' -SimpleMatch | Select-Object -First 3 | ForEach-Object { $_.Line.Trim() })
        }
        $msg = "robocopy exit code $exit"
        if ($errLines.Count) { $msg += ": " + ($errLines -join ' | ') }
        return "$msg (log: $logPath)"
    }
    return $null
}

function Test-UsbExecution {
    $scriptDrive = Split-Path $script:Toolkit.Root -Qualifier
    $driveLetter = $scriptDrive.TrimEnd(':')

    try {
        $disk = Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue |
                Get-Disk -ErrorAction SilentlyContinue
        if ($disk -and $disk.BusType -eq 'USB') {
            $script:Toolkit.IsUsb = $true
            $script:Toolkit.UsbDrive = $driveLetter
            return
        }
    } catch { }

    $script:Toolkit.IsUsb = $false
    $script:Toolkit.UsbDrive = $null
}

function Update-UsbToolkit {
    # Checks the GitHub release feed for a newer toolkit and, if the technician agrees,
    # downloads it, verifies its SHA-256, mirrors it onto the USB and relaunches.
    # Runs before the main window opens, while the console is hidden, so all prompts are message boxes.
    # -KeepClientFolder: client toolkit updating from the CORE feed - the local client\ folder is kept.
    # -LocalVersion: version to compare with the feed (defaults to the toolkit's effective version).
    param(
        [string]$UpdateBaseUrl,
        [switch]$KeepClientFolder,
        [string]$LocalVersion
    )

    if (-not $script:Toolkit.IsUsb) { return }
    if (-not $LocalVersion) { $LocalVersion = $script:Toolkit.Version }
    # A locked USB keeps its client modules and secrets in client\.locked\vault.bin. A client release
    # replaces client\ with plain files, so only core updates (which keep client\) apply to it.
    if (-not $KeepClientFolder -and (Test-Path -LiteralPath (Join-Path $script:Toolkit.Parent 'client\.locked\vault.bin'))) {
        if ($script:Toolkit.OverlayWarnings) { [void]$script:Toolkit.OverlayWarnings.Add('Self-update skipped: this USB is a locked kit. Re-create it from the new version (Make USB) to update it.') }
        return
    }

    Add-Type -AssemblyName PresentationFramework
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $versionUrl = "$UpdateBaseUrl/version.txt"
    $zipUrl     = "$UpdateBaseUrl/latest.zip"
    $hashUrl    = "$UpdateBaseUrl/latest.sha256"

    try {
        $remoteText = (Invoke-WebRequest -Uri $versionUrl -UseBasicParsing -TimeoutSec 5).Content
        if ($remoteText -is [byte[]]) { $remoteText = [System.Text.Encoding]::UTF8.GetString($remoteText) }
        $remoteText = $remoteText.Trim()
        $remoteVersion = [version]$remoteText
        $localVersion  = [version]$LocalVersion
    } catch {
        Write-Host "Offline or update check failed. Continuing with USB version (v$LocalVersion)..." -ForegroundColor Yellow
        return
    }

    if ($remoteVersion -le $localVersion) {
        Write-Host "USB toolkit is up to date (v$LocalVersion)." -ForegroundColor Green
        return
    }

    $choice = [System.Windows.MessageBox]::Show(
        "A newer toolkit is available.`n`nInstalled: v$localVersion`nLatest:    v$remoteVersion`n`nUpdate this USB now?",
        'Toolkit Update Available', 'YesNo', 'Question')
    if ($choice -ne 'Yes') { return }

    $tempZip     = "$env:TEMP\endpoint-toolkit-update.zip"
    $tempExtract = "$env:TEMP\endpoint-toolkit-update"

    $fail = {
        param([string]$Message)
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show(
            "$Message`n`nContinuing with the USB version (v$localVersion).",
            'Update Failed', 'OK', 'Warning') | Out-Null
    }

    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 300
    } catch {
        & $fail "Download failed: $($_.Exception.Message)"
        return
    }

    # SHA-256 integrity verification (mandatory)
    try {
        $expectedHash = (Invoke-WebRequest -Uri $hashUrl -UseBasicParsing -TimeoutSec 10).Content
        if ($expectedHash -is [byte[]]) { $expectedHash = [System.Text.Encoding]::UTF8.GetString($expectedHash) }
        $expectedHash = ($expectedHash.Trim() -split '\s+')[0].ToLower()
    } catch {
        & $fail 'Could not download the checksum file, so the update cannot be verified.'
        return
    }
    if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
        & $fail 'The checksum file is not in the expected format, so the update cannot be verified.'
        return
    }
    $actualHash = (Get-FileHash -Path $tempZip -Algorithm SHA256).Hash.ToLower()
    if ($actualHash -ne $expectedHash) {
        & $fail "Integrity check failed.`nExpected: $expectedHash`nActual:   $actualHash"
        return
    }

    # Extract and deploy
    try {
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
    } catch {
        & $fail "Could not extract the update: $($_.Exception.Message)"
        return
    }

    $extractedItems = @(Get-ChildItem $tempExtract)
    $sourceDir = if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer) {
        $extractedItems[0].FullName
    } else {
        $tempExtract
    }
    if (-not (Test-Path (Join-Path $sourceDir 'dependencies\Invoke-EndpointSetup.ps1'))) {
        & $fail "The downloaded package does not look like a $(Get-ToolkitProductName) release."
        return
    }
    $hasLocalClient  = Test-Path (Join-Path $script:Toolkit.Parent 'client')
    $hasSourceClient = Test-Path (Join-Path $sourceDir 'client')
    if ($KeepClientFolder) {
        # Core feed for a client toolkit: the release must be plain core; the local client\ is preserved below.
        if ($hasSourceClient) {
            & $fail 'The downloaded core release unexpectedly contains a client folder, so it was not applied.'
            return
        }
    } elseif ($hasLocalClient -and -not $hasSourceClient) {
        # A client USB on its own feed must only take client releases: a core-only release would delete client\.
        & $fail 'The downloaded release does not contain this toolkit''s client customizations (client folder), so it was not applied. Check UpdateSource / UpdateBaseUrl in client\branding.json.'
        return
    }

    $common = @('/NFL', '/NDL', '/NJH', '/NJS', '/R:2', '/W:1')
    # Pass 1: mirror everything except CustomInstallers, so files removed from the release are removed here too.
    # With -KeepClientFolder the local client\ folder is excluded from the mirror (kept as is).
    $keepClientArg = if ($KeepClientFolder) { @('client') } else { @() }
    $mirrorArgs = @(
        (ConvertTo-RobocopyPathArg $sourceDir),
        (ConvertTo-RobocopyPathArg $script:Toolkit.Parent),
        '/MIR',
        '/XD', '.git', '.github', '.claude', '.vscode', 'Installers', 'CustomInstallers', '_builds', '"System Volume Information"', '$RECYCLE.BIN') + $keepClientArg + @(
        '/XF', '.gitignore', '.toolkit-key', 'build.ps1'
    ) + $common
    $p1 = Start-Process robocopy -ArgumentList $mirrorArgs -Wait -PassThru -WindowStyle Hidden

    # Pass 2: add/refresh shipped CustomInstallers (core and client) without deleting installers the technician added.
    # Pass 1 skips every folder named CustomInstallers, including client\CustomInstallers.
    $exit2 = 0
    $customPairs = @(
        @{ Src = (Join-Path $sourceDir 'dependencies\CustomInstallers'); Dst = (Join-Path $script:Toolkit.Root 'CustomInstallers') },
        @{ Src = (Join-Path $sourceDir 'client\CustomInstallers');       Dst = (Join-Path $script:Toolkit.Parent 'client\CustomInstallers') }
    )
    foreach ($pair in $customPairs) {
        if (-not (Test-Path $pair.Src)) { continue }
        $customArgs = @(
            (ConvertTo-RobocopyPathArg $pair.Src),
            (ConvertTo-RobocopyPathArg $pair.Dst),
            '/E'
        ) + $common
        $e = (Start-Process robocopy -ArgumentList $customArgs -Wait -PassThru -WindowStyle Hidden).ExitCode
        if ($e -gt $exit2) { $exit2 = $e }
    }

    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

    if ($p1.ExitCode -ge 8 -or $exit2 -ge 8) {
        [System.Windows.MessageBox]::Show(
            "Copying the update to the USB failed (robocopy exit codes $($p1.ExitCode)/$exit2).`nThe USB may be partly updated; re-run the update or rebuild the USB.",
            'Update Failed', 'OK', 'Error') | Out-Null
        return
    }

    Write-Host "USB updated to v$remoteVersion. Relaunching..." -ForegroundColor Green
    $updatedScript = Join-Path $script:Toolkit.Root 'Invoke-EndpointSetup.ps1'
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }
    Start-Process $psExe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$updatedScript`"" -Verb RunAs
    exit
}
