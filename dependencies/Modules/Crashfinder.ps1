# Module: Crashfinder.ps1

function Register-Crashfinder {
    @{
        Name         = 'Crashfinder'
        Label        = 'Crashfinder'
        Description  = 'Read-only freeze and crash health report'
        RequiresAuth = $false
        SortOrder    = 45
        EntryPoint   = 'Start-Crashfinder'
        UIDefinition = 'Get-CrashfinderUI'
    }
}

function Get-CrashfinderUI {
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)

    $accentBrush = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#89B4FA'))
    $dimBrush = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#A6ADC8'))
    $textBrush = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#CDD6F4'))

    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = 'Crashfinder'
    $header.FontSize = 22
    $header.FontWeight = 'Bold'
    $header.Foreground = $accentBrush
    $header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $panel.Children.Add($header) | Out-Null

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = 'Read-only freeze and crash health check. Collects bugchecks, hardware/driver errors, app hangs, disk health, power settings and more from the last 30 days. Changes nothing on the PC.'
    $desc.FontSize = 13
    $desc.Foreground = $dimBrush
    $desc.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)
    $desc.TextWrapping = 'Wrap'
    $panel.Children.Add($desc) | Out-Null

    $outLabel = New-Object System.Windows.Controls.Label
    $outLabel.Content = 'REPORT'
    $outLabel.FontWeight = 'Bold'
    $outLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $panel.Children.Add($outLabel) | Out-Null

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)

    $runBtn = New-Object System.Windows.Controls.Button
    $runBtn.Content = 'Run Crashfinder'
    $runBtn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $runBtn.FontWeight = 'Bold'
    $runBtn.Background = $accentBrush
    $runBtn.Foreground = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#1E1E2E'))
    $btnRow.Children.Add($runBtn) | Out-Null

    $openBtn = New-Object System.Windows.Controls.Button
    $openBtn.Content = 'Open Report Folder'
    $openBtn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $openBtn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $btnRow.Children.Add($openBtn) | Out-Null

    $panel.Children.Add($btnRow) | Out-Null

    $statusText = New-Object System.Windows.Controls.TextBlock
    $statusText.Text = 'Reports are saved to C:\_INFO\Crashfinder'
    $statusText.FontSize = 13
    $statusText.Foreground = $textBrush
    $statusText.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $statusText.TextWrapping = 'Wrap'
    $statusText.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0)
    $panel.Children.Add($statusText) | Out-Null

    $Global:SyncHash.Crashfinder = @{
        RunBtn     = $runBtn
        StatusText = $statusText
    }

    $openBtn.Add_Click({
        $dir = 'C:\_INFO\Crashfinder'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList $dir
    }.GetNewClosure())

    $runBtn.Add_Click({
        $Global:SyncHash.Crashfinder.RunBtn.IsEnabled = $false
        $Global:SyncHash.Crashfinder.RunBtn.Content = 'Running...'
        $Global:SyncHash.Crashfinder.StatusText.Text = 'Collecting data (about 30 seconds)...'

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
            . (Join-Path $toolkitRoot 'Modules\Crashfinder.ps1')

            $statusMsg = $null
            try {
                Write-Log 'Crashfinder: collecting diagnostics...' -Level Info
                $path = Invoke-Crashfinder -Quiet
                Write-Log "Crashfinder: report saved to $path" -Level Success
                $statusMsg = "Report saved to $path (and .html)"
            } catch {
                Write-Log "Crashfinder failed: $($_.Exception.Message)" -Level Error
                $statusMsg = "Failed: $($_.Exception.Message)"
            } finally {
                $SyncHash.Window.Dispatcher.Invoke([action]{
                    $SyncHash.Crashfinder.RunBtn.IsEnabled = $true
                    $SyncHash.Crashfinder.RunBtn.Content = 'Run Crashfinder'
                    $SyncHash.Crashfinder.StatusText.Text = $statusMsg
                })
            }
        }) | Out-Null
        $ps.BeginInvoke() | Out-Null
    }.GetNewClosure())

    $scroll.Content = $panel
    return $scroll
}

function Start-Crashfinder {
    $path = Invoke-Crashfinder -Quiet
    Write-Log "Crashfinder: report saved to $path" -Level Success
}

function Invoke-Crashfinder {
    param(
        [int]$Days = 30,
        [string]$OutDir = 'C:\_INFO\Crashfinder',
        [switch]$Quiet
    )

    $Since = (Get-Date).AddDays(-$Days)
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $Out = Join-Path $OutDir "Crashfinder_$($env:COMPUTERNAME)_$(Get-Date -f yyyyMMdd-HHmm).txt"
    $r = New-Object System.Collections.Generic.List[string]
    function Write-Section($t) { $r.Add(""); $r.Add("==== $t ====") }
    function Add-Report($o) { ($o | Out-String -Width 200).TrimEnd().Split("`n") | ForEach-Object { $r.Add($_.TrimEnd()) } }

    # --- System overview
    Write-Section "SYSTEM"
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $bio = Get-CimInstance Win32_BIOS
    $up  = (Get-Date) - $os.LastBootUpTime
    $r.Add("PC: $env:COMPUTERNAME  Model: $($cs.Manufacturer) $($cs.Model)  Svc tag: $($bio.SerialNumber)  BIOS: $($bio.SMBIOSBIOSVersion) ($($bio.ReleaseDate))")
    $r.Add("OS: $($os.Caption) build $($os.BuildNumber)  Last boot: $($os.LastBootUpTime)  Uptime: $([int]$up.TotalDays)d $($up.Hours)h")
    $totGB = [math]::Round($os.TotalVisibleMemorySize/1MB,1); $freeGB = [math]::Round($os.FreePhysicalMemory/1MB,1)
    $r.Add("RAM: $totGB GB total, $freeGB GB free  |  Commit: $([math]::Round(($os.TotalVirtualMemorySize-$os.FreeVirtualMemory)/1MB,1)) / $([math]::Round($os.TotalVirtualMemorySize/1MB,1)) GB")
    Add-Report (Get-CimInstance Win32_PhysicalMemory | Select-Object BankLabel, @{n='GB';e={$_.Capacity/1GB}}, Speed, Manufacturer, PartNumber)

    # --- Crashes / hard resets / bugchecks
    Write-Section "UNEXPECTED SHUTDOWNS / BLUESCREENS (last $Days days)"
    $sys = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$Since} -ErrorAction SilentlyContinue
    Add-Report ($sys | Where-Object { ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41) -or $_.Id -eq 6008 -or
            ($_.ProviderName -match 'BugCheck|WER-SystemErrorReporting' -and $_.Id -eq 1001) } |
        Select-Object TimeCreated, Id, ProviderName,
            @{n='Bugcheck';e={
                if ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41 -and $_.Properties.Count -ge 2) {
                    '0x{0:X} (p1 0x{1:X})' -f [uint32]$_.Properties[0].Value, [uint64]$_.Properties[1].Value
                } else { '' }
            }},
            @{n='Msg';e={($_.Message -split "`n")[0].Trim()}} | Format-Table -AutoSize)
    $r.Add("Bugcheck 0x0 = hard freeze / power loss with no bluescreen recorded.")
    $dumps = Get-ChildItem C:\Windows\Minidump -ErrorAction SilentlyContinue
    $r.Add("Minidumps: $(@($dumps).Count)  " + (($dumps | Sort-Object LastWriteTime -Desc | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', '))

    # --- LiveKernelReports (WATCHDOG etc. - freezes that never produce a bluescreen)
    Write-Section "LIVE KERNEL REPORTS (last $Days days)"
    $lkrRoot = 'C:\Windows\LiveKernelReports'
    if (Test-Path $lkrRoot) {
        $lkr = Get-ChildItem $lkrRoot -Recurse -Depth 1 -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $Since }
        if ($lkr) {
            Add-Report ($lkr | Group-Object { $_.Directory.Name } | Sort-Object Count -Desc |
                Select-Object Count, @{n='Type';e={$_.Name}},
                              @{n='Last';e={($_.Group | Sort-Object LastWriteTime -Desc)[0].LastWriteTime}},
                              @{n='SizeMB';e={[math]::Round(($_.Group | Measure-Object Length -Sum).Sum/1MB,1)}} | Format-Table -AutoSize)
            Add-Report ($lkr | Sort-Object LastWriteTime -Desc | Select-Object -First 10 LastWriteTime,
                @{n='Type';e={$_.Directory.Name}}, Name, @{n='SizeMB';e={[math]::Round($_.Length/1MB,1)}} | Format-Table -AutoSize)
        } else {
            $r.Add("No live kernel reports in window.")
        }
    } else {
        $r.Add("LiveKernelReports folder not present.")
    }

    # --- Hardware errors: WHEA, disk, storage controller, GPU driver resets
    Write-Section "HARDWARE / DISK / DRIVER ERRORS (last $Days days)"
    $hw = $sys | Where-Object {
          $_.ProviderName -match 'WHEA-Logger' -or
         ($_.ProviderName -match '^disk$|stornvme|storahci|iaStor|Ntfs' -and $_.Level -le 3) -or
         ($_.ProviderName -eq 'Display' -and $_.Id -eq 4101) -or
         ($_.ProviderName -match 'Resource-Exhaustion' ) }
    Add-Report ($hw | Group-Object ProviderName, Id | Sort-Object Count -Desc |
        Select-Object Count, Name, @{n='Last';e={($_.Group | Sort-Object TimeCreated -Desc)[0].TimeCreated}},
                      @{n='Sample';e={(($_.Group[0].Message) -split "`n")[0].Trim()}} | Format-Table -AutoSize -Wrap)

    # --- App hangs / crashes (freezing users often show as 1002 hangs)
    Write-Section "APPLICATION HANGS (1002) & CRASHES (1000) - last $Days days"
    $app = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error','Application Hang'; Id=1000,1002; StartTime=$Since} -ErrorAction SilentlyContinue
    Add-Report ($app | ForEach-Object { [pscustomobject]@{ Type = if($_.Id -eq 1002){'Hang'}else{'Crash'}; App = $_.Properties[0].Value; Time=$_.TimeCreated } } |
        Group-Object Type, App | Sort-Object Count -Desc | Select-Object -First 15 Count, Name,
        @{n='Last';e={($_.Group | Sort-Object Time -Desc)[0].Time}} | Format-Table -AutoSize)

    # --- Reliability Monitor summary
    Write-Section "RELIABILITY MONITOR (last $Days days)"
    $rel = Get-CimInstance Win32_ReliabilityRecords -ErrorAction SilentlyContinue |
           Where-Object { $_.TimeGenerated -gt $Since -and $_.SourceName -notmatch 'MsiInstaller|Windows Update' }
    Add-Report ($rel | Group-Object ProductName | Sort-Object Count -Desc | Select-Object -First 10 Count, Name | Format-Table -AutoSize)
    $stab = Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction SilentlyContinue | Sort-Object TimeGenerated -Desc | Select-Object -First 1
    if ($stab) { $r.Add("Current stability index: $([math]::Round($stab.SystemStabilityIndex,2)) / 10") }

    # --- Disk health
    Write-Section "DISK HEALTH"
    Add-Report (Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus, @{n='GB';e={[int]($_.Size/1GB)}} | Format-Table -AutoSize)
    Add-Report (Get-PhysicalDisk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue |
         Select-Object DeviceId, Temperature, Wear, ReadErrorsTotal, WriteErrorsTotal, PowerOnHours | Format-Table -AutoSize)
    Add-Report (Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, HealthStatus,
         @{n='FreeGB';e={[int]($_.SizeRemaining/1GB)}}, @{n='SizeGB';e={[int]($_.Size/1GB)}} | Format-Table -AutoSize)

    # --- What is using the machine right now
    Write-Section "TOP PROCESSES - MEMORY"
    Add-Report (Get-Process | Sort-Object WorkingSet64 -Desc | Select-Object -First 12 Name, Id,
         @{n='MemMB';e={[int]($_.WorkingSet64/1MB)}}, @{n='CPUsec';e={[int]$_.CPU}} | Format-Table -AutoSize)
    Write-Section "TOP PROCESSES - CPU (5 sec sample)"
    $c = Get-Counter '\Process(*)\% Processor Time' -SampleInterval 5 -MaxSamples 1 -ErrorAction SilentlyContinue
    Add-Report ($c.CounterSamples | Where-Object { $_.InstanceName -notmatch '^(_total|idle)$' } | Sort-Object CookedValue -Desc |
         Select-Object -First 10 @{n='Process';e={$_.InstanceName}}, @{n='CPU%';e={[math]::Round($_.CookedValue/$cs.NumberOfLogicalProcessors,1)}} | Format-Table -AutoSize)

    # --- Power / Fast Startup
    Write-Section "POWER / FAST STARTUP"
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $plan = (powercfg /getactivescheme 2>$null) -join ' '
    $fast = (Get-ItemProperty $powerKey -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    $hib  = (Get-ItemProperty $powerKey -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
    $r.Add("Active plan: $plan")
    $r.Add("Fast Startup (HiberbootEnabled): $(if ($null -eq $fast) {'n/a'} else {$fast})  |  Hibernate (HibernateEnabled): $(if ($null -eq $hib) {'n/a'} else {$hib})")
    $boots = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Boot'; Id=27} -MaxEvents 5 -ErrorAction SilentlyContinue
    if ($boots) {
        $bootTypes = @{ 0 = 'Cold boot'; 1 = 'Fast Startup'; 2 = 'Resume from hibernate' }
        Add-Report ($boots | Select-Object TimeCreated, @{n='BootType';e={
            $t = [int]$_.Properties[0].Value
            if ($bootTypes.ContainsKey($t)) { $bootTypes[$t] } else { "Unknown ($t)" } }} | Format-Table -AutoSize)
    }

    # --- Security agents / startup load / stopped auto services
    Write-Section "SECURITY & STARTUP"
    Add-Report (Get-CimInstance -Namespace root/SecurityCenter2 AntiVirusProduct -ErrorAction SilentlyContinue | Select-Object displayName, productState | Format-Table -AutoSize)
    Add-Report (Get-Service | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' } | Select-Object Name, DisplayName, Status | Format-Table -AutoSize)
    Add-Report (Get-CimInstance Win32_StartupCommand | Select-Object Name, Location, User | Format-Table -AutoSize)

    # --- Patching / pending reboot / drivers
    Write-Section "UPDATES / PENDING REBOOT / GRAPHICS DRIVER"
    Add-Report (Get-HotFix | Sort-Object InstalledOn -Desc -ErrorAction SilentlyContinue | Select-Object -First 5 HotFixID, InstalledOn | Format-Table -AutoSize)
    $pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $r.Add("Pending reboot: $pend")
    Add-Report (Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, DriverDate | Format-Table -AutoSize)

    $r | Set-Content -Path $Out -Encoding UTF8

    # --- HTML version (same content, sectioned with sidebar nav, collapsible, searchable)
    try {
        $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
        $sections = New-Object System.Collections.Generic.List[object]
        $cur = $null
        foreach ($line in $r) {
            if ($line -match '^==== (.+) ====$') {
                $cur = [pscustomobject]@{ Title = $Matches[1]; Lines = New-Object System.Collections.Generic.List[string] }
                $sections.Add($cur)
            } elseif ($cur) { $cur.Lines.Add($line) }
        }
        $nav  = New-Object System.Text.StringBuilder
        $body = New-Object System.Text.StringBuilder
        $i = 0
        foreach ($s in $sections) {
            $i++
            $text = ($s.Lines -join "`n").Trim("`n")
            if (-not $text.Trim()) { $text = '(no data)' }
            $flag = ''
            if ($s.Title -match '^(UNEXPECTED|HARDWARE|LIVE KERNEL|APPLICATION HANGS)' -and $text -match '\d') {
                if ($text -notmatch '^(No live kernel|LiveKernelReports folder not present|\(no data\))') { $flag = ' <span class="badge">review</span>' }
            }
            [void]$nav.AppendLine("<a href=`"#s$i`">$(& $enc $s.Title)$flag</a>")
            [void]$body.AppendLine("<details open id=`"s$i`"><summary>$(& $enc $s.Title)$flag</summary><pre>$(& $enc $text)</pre></details>")
        }
        $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Crashfinder - $(& $enc $env:COMPUTERNAME)</title>
<style>
:root{--bg:#fff;--fg:#1c2128;--mut:#656d76;--card:#f6f8fa;--bd:#d0d7de;--acc:#0969da}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--mut:#8b949e;--card:#161b22;--bd:#30363d;--acc:#58a6ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 Segoe UI,system-ui,sans-serif;display:flex}
nav{position:sticky;top:0;align-self:flex-start;height:100vh;width:260px;overflow:auto;padding:16px;border-right:1px solid var(--bd);background:var(--card);flex:none}
nav h1{font-size:15px;margin:0 0 4px}nav p{margin:0 0 12px;color:var(--mut);font-size:12px}
nav a{display:block;padding:5px 8px;border-radius:6px;color:var(--fg);text-decoration:none;font-size:13px}
nav a:hover{background:var(--bd)}
main{flex:1;min-width:0;padding:16px 24px 64px}
input{width:100%;padding:8px 10px;border:1px solid var(--bd);border-radius:6px;background:var(--bg);color:var(--fg);margin-bottom:12px}
details{border:1px solid var(--bd);border-radius:8px;margin-bottom:12px;background:var(--card)}
summary{cursor:pointer;padding:10px 14px;font-weight:600}
pre{margin:0;padding:12px 14px;border-top:1px solid var(--bd);overflow:auto;font:12.5px/1.45 Consolas,monospace}
.badge{background:#d29922;color:#000;border-radius:10px;padding:0 7px;font-size:11px;font-weight:600;margin-left:6px}
mark{background:#ffd33d;color:#000}
@media(max-width:800px){body{display:block}nav{position:static;height:auto;width:auto}}
</style></head><body>
<nav><h1>Crashfinder</h1><p>$(& $enc $env:COMPUTERNAME)<br>$(Get-Date -f 'yyyy-MM-dd HH:mm') &middot; last $Days days</p>
$($nav.ToString())</nav>
<main><input id="q" type="search" placeholder="Filter report text..." autofocus>
$($body.ToString())
</main>
<script>
const q=document.getElementById('q'),ds=[...document.querySelectorAll('details')],orig=ds.map(d=>d.querySelector('pre').innerHTML);
q.addEventListener('input',()=>{const t=q.value.trim().toLowerCase();ds.forEach((d,i)=>{const p=d.querySelector('pre');p.innerHTML=orig[i];
if(!t){d.style.display='';return}
const hit=p.textContent.toLowerCase().includes(t)||d.querySelector('summary').textContent.toLowerCase().includes(t);
d.style.display=hit?'':'none';if(hit){d.open=true;const esc=t.replace(/[.*+?^`${}()|[\]\\]/g,'\\`$&');
p.innerHTML=orig[i].replace(new RegExp('('+esc.replace(/&/g,'&amp;')+')','gi'),'<mark>`$1</mark>')}})});
</script></body></html>
"@
        $htmlPath = [System.IO.Path]::ChangeExtension($Out, '.html')
        Set-Content -Path $htmlPath -Value $html -Encoding UTF8
    } catch {
        Write-Warning "Crashfinder: HTML report failed: $($_.Exception.Message)"
    }

    if (-not $Quiet) { $r | Write-Output; Write-Output "`nReport saved to $Out (+ .html)" }
    return $Out
}
