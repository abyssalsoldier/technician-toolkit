# Module: Migration-Assist.ps1
# Exports printers (with driver packages), mapped drives, Wi-Fi/network settings and
# system settings from one Windows install into a bundle folder, and imports them
# on another. Secrets (Wi-Fi keys, credential names) are encrypted with a passphrase.
# NOTE: keep this file ASCII-only (PowerShell 5.1 reads BOM-less files as ANSI).

function Register-MigrationAssist {
    @{
        Name         = 'Migration-Assist'
        Label        = 'Migration Assist'
        Description  = 'Export and import printers, drives, Wi-Fi and settings between Windows installs'
        RequiresAuth = $false
        SortOrder    = 47
        EntryPoint   = 'Start-MigrationAssist'
        UIDefinition = 'Get-MigrationAssistUI'
    }
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Write-MaLog {
    param([string]$Message, [string]$Level = 'Info')
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "Migration: $Message" -Level $Level
    } else {
        Write-Host "Migration: $Message"
    }
}

function Assert-MaAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Migration Assist must run as Administrator.'
    }
}

function Add-MaResult {
    param(
        [System.Collections.ArrayList]$Results,
        [string]$Category,
        [string]$Item,
        [ValidateSet('OK', 'Skipped', 'Warning', 'Failed', 'Preview')][string]$Status,
        [string]$Detail = ''
    )
    $Results.Add([pscustomobject]@{
        Category = $Category
        Item     = $Item
        Status   = $Status
        Detail   = $Detail
    }) | Out-Null
    $level = switch ($Status) {
        'OK'      { 'Success' }
        'Warning' { 'Warning' }
        'Failed'  { 'Error' }
        default   { 'Info' }
    }
    $line = "[$Category] $Item - $Status"
    if ($Detail) { $line += ": $Detail" }
    Write-MaLog $line $level
}

function Get-MaSafeName {
    param([string]$Name)
    $n = ($Name -replace '[^\w\.\- ]', '_').Trim()
    if (-not $n) { $n = '_' }
    return $n
}

function Invoke-MaProcess {
    # Runs an executable with a timeout. Returns @{ ExitCode; Output; TimedOut }.
    param([string]$FilePath, [string]$Arguments, [int]$TimeoutSec = 300)
    $outFile = Join-Path $env:TEMP ("ma_out_" + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path $env:TEMP ("ma_err_" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $null = $p.Handle
        $timedOut = $false
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            try { $p.Kill() } catch { }
        }
        $text = ''
        if (Test-Path $outFile) { $text += (Get-Content $outFile -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path $errFile) { $text += (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) }
        $code = -1
        if (-not $timedOut) { $code = $p.ExitCode }
        return @{ ExitCode = $code; Output = $text; TimedOut = $timedOut }
    } finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Save-MaJson {
    param($Data, [string]$Path)
    # Wrap in @() so single items still serialize as arrays on the way in.
    ConvertTo-Json -InputObject $Data -Depth 6 | Set-Content -Path $Path -Encoding UTF8
}

function Read-MaJson {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { return @() }
    return @($raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Secrets encryption: PBKDF2(SHA256, 100k) -> AES-256-CBC + HMAC-SHA256
# File layout: "MAS1" | salt(16) | iv(16) | ciphertext | hmac(32)
# ---------------------------------------------------------------------------

function ConvertTo-MaKeys {
    param([string]$Passphrase, [byte[]]$Salt)
    $d = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Passphrase, $Salt, 100000, 'SHA256')
    $enc = $d.GetBytes(32)
    $mac = $d.GetBytes(32)
    $d.Dispose()
    return @{ Enc = $enc; Mac = $mac }
}

function Protect-MigrationSecrets {
    param([string]$SourceDir, [string]$OutFile, [string]$Passphrase)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $env:TEMP ("ma_sec_" + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory($SourceDir, $zip)
        $plain = [System.IO.File]::ReadAllBytes($zip)
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }

    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt)
    $keys = ConvertTo-MaKeys -Passphrase $Passphrase -Salt $salt

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $keys.Enc
    $aes.GenerateIV()
    $cipher = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)

    $ms = New-Object System.IO.MemoryStream
    $magic = [System.Text.Encoding]::ASCII.GetBytes('MAS1')
    $ms.Write($magic, 0, $magic.Length)
    $ms.Write($salt, 0, $salt.Length)
    $ms.Write($aes.IV, 0, $aes.IV.Length)
    $ms.Write($cipher, 0, $cipher.Length)
    $body = $ms.ToArray()

    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $keys.Mac)
    $tag = $hmac.ComputeHash($body)

    $final = New-Object byte[] ($body.Length + $tag.Length)
    [Array]::Copy($body, 0, $final, 0, $body.Length)
    [Array]::Copy($tag, 0, $final, $body.Length, $tag.Length)
    [System.IO.File]::WriteAllBytes($OutFile, $final)
    $aes.Dispose()
}

function Unprotect-MigrationSecrets {
    param([string]$File, [string]$DestDir, [string]$Passphrase)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $all = [System.IO.File]::ReadAllBytes($File)
    if ($all.Length -lt (4 + 16 + 16 + 32 + 16)) { throw 'secrets.enc is too small or corrupted.' }
    if ([System.Text.Encoding]::ASCII.GetString($all, 0, 4) -ne 'MAS1') { throw 'secrets.enc has an unknown format.' }

    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    [Array]::Copy($all, 4, $salt, 0, 16)
    [Array]::Copy($all, 20, $iv, 0, 16)
    $keys = ConvertTo-MaKeys -Passphrase $Passphrase -Salt $salt

    $bodyLen = $all.Length - 32
    $body = New-Object byte[] $bodyLen
    [Array]::Copy($all, 0, $body, 0, $bodyLen)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $keys.Mac)
    $expected = $hmac.ComputeHash($body)
    $diff = 0
    for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($expected[$i] -bxor $all[$bodyLen + $i]) }
    if ($diff -ne 0) { throw 'Wrong passphrase, or the secrets file is corrupted.' }

    $cipherLen = $bodyLen - 36
    $cipher = New-Object byte[] $cipherLen
    [Array]::Copy($all, 36, $cipher, 0, $cipherLen)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $keys.Enc
    $aes.IV = $iv
    $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)
    $aes.Dispose()

    $zip = Join-Path $env:TEMP ("ma_sec_" + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        [System.IO.File]::WriteAllBytes($zip, $plain)
        if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $DestDir)
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Category: Printers
# ---------------------------------------------------------------------------

function Test-MaVirtualPrinter {
    param($Printer)
    if ($Printer.PortName -match '^(PORTPROMPT:|nul:|SHRFAX:|XPSPort:|FILE:)$') { return $true }
    if ($Printer.PortName -match '^Microsoft\.Office\.OneNote') { return $true }
    if ($Printer.DriverName -match '^(Microsoft (Print To PDF|XPS Document Writer|Shared Fax Driver|Software Printer Writer)|Send to Microsoft OneNote)') { return $true }
    if ($Printer.Name -match '^(OneNote|Fax$|Microsoft (Print to PDF|XPS))') { return $true }
    return $false
}

function Invoke-MaPrintBrm {
    # PrintBrm does not strip quotes from -F paths and exits 0 even on failure, so:
    #  - it is always given a plain space-free path under %windir%\Temp (file is copied/moved as needed)
    #  - success is decided from its output, not its exit code
    # Returns @{ Success; Message; TimedOut }.
    param([ValidateSet('Backup', 'Restore')][string]$Mode, [string]$BundleFile, [string]$Overwrite = 'KEEP')
    $brm = Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe'
    $work = New-ToolkitPrivateDirectory -Path (Join-Path $env:windir ('Temp\MaBrm_' + [guid]::NewGuid().ToString('N')))
    $tmpFile = Join-Path $work 'printers.printerExport'
    try {
        if ($Mode -eq 'Backup') {
            $r = Invoke-MaProcess -FilePath $brm -Arguments ('-B -F {0}' -f $tmpFile) -TimeoutSec 1800
        } else {
            Copy-Item -Path $BundleFile -Destination $tmpFile -Force
            $r = Invoke-MaProcess -FilePath $brm -Arguments ('-R -F {0} -O {1}' -f $tmpFile, $Overwrite) -TimeoutSec 1800
        }
        if ($r.TimedOut) { return @{ Success = $false; TimedOut = $true; Message = 'Timed out.' } }

        $ok = ($r.Output -match 'Successfully finished') -and ($r.Output -notmatch 'following error occurred')
        if ($ok -and $Mode -eq 'Backup') {
            if (-not (Test-Path $tmpFile)) { $ok = $false }
            else { Move-Item -Path $tmpFile -Destination $BundleFile -Force }
        }
        if ($ok) { return @{ Success = $true; TimedOut = $false; Message = '' } }

        # Short failure text: the error lines only, not the full queue/driver listing.
        $lines = @($r.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'error occurred') { $idx = $i; break } }
        if ($idx -ge 0) { $msg = ($lines[$idx..([Math]::Min($idx + 2, $lines.Count - 1))] -join ' ') }
        else { $msg = ("exit code {0}" -f $r.ExitCode) }
        return @{ Success = $false; TimedOut = $false; Message = $msg }
    } finally {
        Remove-ToolkitTree -LiteralPath $work
    }
}

function Export-MaPrinters {
    param([string]$Bundle, [System.Collections.ArrayList]$Results, [bool]$IncludeDriverPackages = $true)
    $cat = 'Printers'
    $dir = Join-Path $Bundle 'Printers'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if (-not $spooler -or $spooler.Status -ne 'Running') {
        Add-MaResult $Results $cat 'Print Spooler' 'Failed' 'Print Spooler service is not running.'
        return
    }

    $printers = @(Get-Printer -ErrorAction Stop | Where-Object { -not (Test-MaVirtualPrinter $_) })
    $defaultName = $null
    try {
        $dp = Get-CimInstance -ClassName Win32_Printer -Filter 'Default=True' -ErrorAction Stop
        if ($dp) { $defaultName = $dp.Name }
    } catch { }

    $printerRows = @()
    foreach ($p in $printers) {
        $printerRows += [pscustomobject]@{
            Name       = $p.Name
            DriverName = $p.DriverName
            PortName   = $p.PortName
            Type       = [string]$p.Type
            Shared     = [bool]$p.Shared
            ShareName  = $p.ShareName
            Location   = $p.Location
            Comment    = $p.Comment
            IsDefault  = ($p.Name -eq $defaultName)
        }
    }
    Save-MaJson $printerRows (Join-Path $dir 'printers.json')

    $portNames = @($printers | ForEach-Object { $_.PortName } | Select-Object -Unique)
    $portRows = @()
    foreach ($pn in $portNames) {
        $port = Get-PrinterPort -Name $pn -ErrorAction SilentlyContinue
        if (-not $port) { continue }
        $row = [ordered]@{ Name = $port.Name }
        foreach ($prop in 'PrinterHostAddress', 'PortNumber', 'LprHostAddress', 'LprQueueName', 'LprByteCounting', 'SNMPEnabled', 'SNMPCommunity', 'SNMPIndex') {
            if ($port.PSObject.Properties[$prop]) { $row[$prop] = $port.$prop }
        }
        $portRows += [pscustomobject]$row
    }
    Save-MaJson $portRows (Join-Path $dir 'ports.json')

    foreach ($p in $printerRows) {
        $detail = "driver '$($p.DriverName)', port '$($p.PortName)'"
        Add-MaResult $Results $cat $p.Name 'OK' $detail
    }
    if ($printerRows.Count -eq 0) {
        Add-MaResult $Results $cat 'Printers' 'Skipped' 'No physical printers found.'
        return
    }

    # Full PrintBrm backup (queues, ports, drivers, per-printer settings)
    $brm = Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe'
    if (Test-Path $brm) {
        $brmFile = Join-Path $dir 'printers.printerExport'
        Write-MaLog 'Running PrintBrm backup (this can take a few minutes)...'
        $r = Invoke-MaPrintBrm -Mode Backup -BundleFile $brmFile
        if ($r.TimedOut) {
            Add-MaResult $Results $cat 'PrintBrm backup' 'Warning' 'Timed out; falling back to driver packages only.'
        } elseif ($r.Success) {
            $mb = [math]::Round((Get-Item $brmFile).Length / 1MB, 1)
            Add-MaResult $Results $cat 'PrintBrm backup' 'OK' ("printers.printerExport ({0} MB)" -f $mb)
        } else {
            Add-MaResult $Results $cat 'PrintBrm backup' 'Warning' ("{0} Falling back to driver packages only." -f $r.Message)
        }
    } else {
        Add-MaResult $Results $cat 'PrintBrm backup' 'Warning' 'PrintBrm.exe not found on this system.'
    }

    # Individual driver packages from the driver store
    if ($IncludeDriverPackages) {
        $driverDir = Join-Path $dir 'Drivers'
        New-Item -ItemType Directory -Path $driverDir -Force | Out-Null
        $driverRows = @()
        $copied = @{}
        $driverNames = @($printerRows | ForEach-Object { $_.DriverName } | Select-Object -Unique)
        foreach ($dn in $driverNames) {
            try {
                $drv = Get-PrinterDriver -Name $dn -ErrorAction Stop | Select-Object -First 1
                if ($drv.Manufacturer -eq 'Microsoft' -or $dn -like 'Microsoft *' -or $dn -like 'Remote Desktop Easy Print*') {
                    Add-MaResult $Results $cat "Driver: $dn" 'Skipped' 'Built-in Microsoft driver.'
                    continue
                }
                $inf = $drv.InfPath
                if (-not $inf -or -not (Test-Path $inf)) {
                    Add-MaResult $Results $cat "Driver: $dn" 'Warning' 'No driver-store package found (legacy driver). Needs manual driver install.'
                    continue
                }
                $pkgDir = Split-Path $inf -Parent
                if (-not $copied.ContainsKey($pkgDir)) {
                    $target = Join-Path $driverDir (Get-MaSafeName (Split-Path $pkgDir -Leaf))
                    Copy-Item -Path $pkgDir -Destination $target -Recurse -Force -ErrorAction Stop
                    $copied[$pkgDir] = Split-Path $target -Leaf
                }
                $driverRows += [pscustomobject]@{
                    Name    = $dn
                    Package = $copied[$pkgDir]
                    Inf     = (Split-Path $inf -Leaf)
                }
                Add-MaResult $Results $cat "Driver: $dn" 'OK' "package $($copied[$pkgDir])"
            } catch {
                Add-MaResult $Results $cat "Driver: $dn" 'Failed' $_.Exception.Message
            }
        }
        Save-MaJson $driverRows (Join-Path $dir 'drivers.json')
    }
}

function Import-MaPrinters {
    param([string]$Bundle, [System.Collections.ArrayList]$Results, [bool]$Preview, [bool]$Overwrite)
    $cat = 'Printers'
    $dir = Join-Path $Bundle 'Printers'
    if (-not (Test-Path $dir)) {
        Add-MaResult $Results $cat 'Printers' 'Skipped' 'Not present in bundle.'
        return
    }
    $printers = Read-MaJson (Join-Path $dir 'printers.json')
    $ports = Read-MaJson (Join-Path $dir 'ports.json')
    $drivers = Read-MaJson (Join-Path $dir 'drivers.json')

    $spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if (-not $spooler -or $spooler.Status -ne 'Running') {
        Add-MaResult $Results $cat 'Print Spooler' 'Failed' 'Print Spooler service is not running.'
        return
    }

    if ($Preview) {
        foreach ($p in $printers) {
            $exists = [bool](Get-Printer -Name $p.Name -ErrorAction SilentlyContinue)
            if ($exists) {
                Add-MaResult $Results $cat $p.Name 'Preview' 'Already exists - would skip.'
            } else {
                Add-MaResult $Results $cat $p.Name 'Preview' "Would create (driver '$($p.DriverName)', port '$($p.PortName)')."
            }
        }
        return
    }

    # (a) PrintBrm restore
    $brm = Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe'
    $brmFile = Join-Path $dir 'printers.printerExport'
    if ((Test-Path $brm) -and (Test-Path $brmFile)) {
        $mode = 'KEEP'
        if ($Overwrite) { $mode = 'FORCE' }
        Write-MaLog 'Running PrintBrm restore (this can take a few minutes)...'
        $r = Invoke-MaPrintBrm -Mode Restore -BundleFile $brmFile -Overwrite $mode
        if ($r.TimedOut) {
            Add-MaResult $Results $cat 'PrintBrm restore' 'Warning' 'Timed out; continuing with driver packages.'
        } elseif ($r.Success) {
            Add-MaResult $Results $cat 'PrintBrm restore' 'OK' ''
        } else {
            Add-MaResult $Results $cat 'PrintBrm restore' 'Warning' ("{0} Continuing with driver packages." -f $r.Message)
        }
    }

    # (b) per-printer fallback
    $stagedPackages = @{}
    foreach ($p in $printers) {
        try {
            if (Get-Printer -Name $p.Name -ErrorAction SilentlyContinue) {
                Add-MaResult $Results $cat $p.Name 'OK' 'Present.'
                continue
            }

            # Connections to a print server: re-connect by UNC path.
            if ($p.Name -like '\\*') {
                Add-Printer -ConnectionName $p.Name -ErrorAction Stop
                Add-MaResult $Results $cat $p.Name 'OK' 'Reconnected to print server.'
                continue
            }

            # Driver
            if (-not (Get-PrinterDriver -Name $p.DriverName -ErrorAction SilentlyContinue)) {
                $drvRow = $drivers | Where-Object { $_.Name -eq $p.DriverName } | Select-Object -First 1
                if ($drvRow) {
                    $pkg = Join-Path (Join-Path $dir 'Drivers') $drvRow.Package
                    if (-not $stagedPackages.ContainsKey($pkg)) {
                        $pn = Invoke-MaProcess -FilePath "$env:windir\System32\pnputil.exe" -Arguments ('/add-driver "{0}\*.inf" /subdirs /install' -f $pkg) -TimeoutSec 300
                        if ($pn.ExitCode -ne 0 -and $pn.ExitCode -ne 3010) {
                            Write-MaLog ("pnputil exit {0} for {1}: {2}" -f $pn.ExitCode, $drvRow.Package, $pn.Output.Trim()) 'Warning'
                        }
                        $stagedPackages[$pkg] = $true
                    }
                    Add-PrinterDriver -Name $p.DriverName -ErrorAction Stop
                } else {
                    Add-MaResult $Results $cat $p.Name 'Warning' "Needs manual driver install ('$($p.DriverName)' not in bundle)."
                    continue
                }
            }

            # Port
            if (-not (Get-PrinterPort -Name $p.PortName -ErrorAction SilentlyContinue)) {
                $port = $ports | Where-Object { $_.Name -eq $p.PortName } | Select-Object -First 1
                if ($port -and $port.PrinterHostAddress) {
                    $pnum = 9100
                    if ($port.PortNumber) { $pnum = [int]$port.PortNumber }
                    Add-PrinterPort -Name $p.PortName -PrinterHostAddress $port.PrinterHostAddress -PortNumber $pnum -ErrorAction Stop
                } elseif ($port -and $port.LprHostAddress) {
                    Add-PrinterPort -Name $p.PortName -LprHostAddress $port.LprHostAddress -LprQueueName $port.LprQueueName -ErrorAction Stop
                } elseif ($p.PortName -like 'WSD-*') {
                    Add-MaResult $Results $cat $p.Name 'Warning' 'WSD (auto-discovered) printer has no fixed address. Often a duplicate of another entry; if not, re-add it from Add Printer or by IP.'
                    continue
                } else {
                    Add-MaResult $Results $cat $p.Name 'Warning' "Port '$($p.PortName)' is not portable (USB/local). Add the printer manually."
                    continue
                }
            }

            Add-Printer -Name $p.Name -DriverName $p.DriverName -PortName $p.PortName -ErrorAction Stop
            if ($p.Shared -and $p.ShareName) {
                try { Set-Printer -Name $p.Name -Shared $true -ShareName $p.ShareName -ErrorAction Stop } catch { }
            }
            if ($p.Location -or $p.Comment) {
                try { Set-Printer -Name $p.Name -Location $p.Location -Comment $p.Comment -ErrorAction Stop } catch { }
            }
            Add-MaResult $Results $cat $p.Name 'OK' 'Created.'
        } catch {
            Add-MaResult $Results $cat $p.Name 'Failed' $_.Exception.Message
        }
    }

    # (d) default printer
    $def = $printers | Where-Object { $_.IsDefault } | Select-Object -First 1
    if ($def -and (Get-Printer -Name $def.Name -ErrorAction SilentlyContinue)) {
        try {
            (New-Object -ComObject WScript.Network).SetDefaultPrinter($def.Name)
            Add-MaResult $Results $cat 'Default printer' 'OK' $def.Name
        } catch {
            Add-MaResult $Results $cat 'Default printer' 'Warning' $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Category: Network drives and credentials
# ---------------------------------------------------------------------------

function Export-MaNetworkDrives {
    param([string]$Bundle, [string]$SecretsDir, [System.Collections.ArrayList]$Results)
    $cat = 'NetworkDrives'
    $dir = Join-Path $Bundle 'NetworkDrives'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $rows = @()
    $hives = Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' }
    foreach ($h in $hives) {
        $netKey = "Registry::$($h.Name)\Network"
        if (-not (Test-Path $netKey)) { continue }
        $user = $h.PSChildName
        try { $user = (New-Object Security.Principal.SecurityIdentifier($h.PSChildName)).Translate([Security.Principal.NTAccount]).Value } catch { }
        foreach ($k in (Get-ChildItem $netKey -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if (-not $props.RemotePath) { continue }
            $uname = $null
            if ($props.UserName -and $props.UserName -ne 0) { $uname = [string]$props.UserName }
            $rows += [pscustomobject]@{
                Owner      = $user
                Letter     = $k.PSChildName.ToUpper()
                RemotePath = [string]$props.RemotePath
                UserName   = $uname
            }
        }
    }
    Save-MaJson $rows (Join-Path $dir 'drives.json')
    foreach ($r in $rows) {
        $d = "$($r.Owner) -> $($r.RemotePath)"
        if ($r.UserName) { $d += " (as $($r.UserName))" }
        Add-MaResult $Results $cat ($r.Letter + ':') 'OK' $d
    }
    if ($rows.Count -eq 0) {
        Add-MaResult $Results $cat 'Mapped drives' 'Skipped' 'No persistent mapped drives in any loaded user profile.'
    }

    # Credential Manager target names (passwords cannot be read)
    $creds = @()
    try {
        $raw = (& cmdkey.exe /list 2>&1) | Out-String
        $cur = $null
        foreach ($line in ($raw -split "`r?`n")) {
            if ($line -match '^\s*Target:\s*(.+)$') {
                if ($cur) { $creds += [pscustomobject]$cur }
                $cur = [ordered]@{ Target = $Matches[1].Trim(); Type = ''; User = '' }
            } elseif ($cur -and $line -match '^\s*Type:\s*(.+)$') {
                $cur.Type = $Matches[1].Trim()
            } elseif ($cur -and $line -match '^\s*User:\s*(.+)$') {
                $cur.User = $Matches[1].Trim()
            }
        }
        if ($cur) { $creds += [pscustomobject]$cur }
    } catch {
        Add-MaResult $Results $cat 'Credential Manager' 'Warning' $_.Exception.Message
    }
    $credDir = Join-Path $SecretsDir 'Credentials'
    New-Item -ItemType Directory -Path $credDir -Force | Out-Null
    Save-MaJson $creds (Join-Path $credDir 'credentials.json')
    Add-MaResult $Results $cat 'Saved credentials' 'OK' ("{0} entries (names only; passwords are not exportable)" -f $creds.Count)
}

function Import-MaNetworkDrives {
    param([string]$Bundle, [string]$SecretsDir, [System.Collections.ArrayList]$Results, [bool]$Preview)
    $cat = 'NetworkDrives'
    $dir = Join-Path $Bundle 'NetworkDrives'
    if (-not (Test-Path $dir)) {
        Add-MaResult $Results $cat 'Network drives' 'Skipped' 'Not present in bundle.'
        return
    }
    $drives = Read-MaJson (Join-Path $dir 'drives.json')
    Write-MaLog "Drives are mapped for the signed-in account ($env:USERNAME). Run as the user who will use them." 'Info'
    foreach ($d in $drives) {
        $item = $d.Letter + ':'
        $letter = $d.Letter.TrimEnd(':')
        try {
            $inUse = (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue) -or (Test-Path "HKCU:\Network\$letter")
            if ($inUse) {
                Add-MaResult $Results $cat $item $(if ($Preview) { 'Preview' } else { 'Skipped' }) 'Letter already in use.'
                continue
            }
            if ($Preview) {
                Add-MaResult $Results $cat $item 'Preview' "Would map to $($d.RemotePath)"
                continue
            }
            New-SmbMapping -LocalPath ($letter + ':') -RemotePath $d.RemotePath -Persistent $true -ErrorAction Stop | Out-Null
            Add-MaResult $Results $cat $item 'OK' "Mapped to $($d.RemotePath). May appear in Explorer after sign-out/in."
        } catch {
            $why = $_.Exception.Message
            if ($d.UserName) { $why += " Originally connected as $($d.UserName); re-enter the credentials and map again." }
            Add-MaResult $Results $cat $item 'Warning' $why
        }
    }

    $credFile = Join-Path $SecretsDir 'Credentials\credentials.json'
    if (Test-Path $credFile) {
        $creds = Read-MaJson $credFile
        # App-managed tokens (sign-in caches) are recreated when the app signs in again.
        $appNoise = '^(MicrosoftAccount:|WindowsLive:|LegacyGeneric:target=(MicrosoftAccount:|WindowsLive:|Microsoft_|Adobe|Olk/|1Password|SSO_POP|virtualapp|MSIX|OneDrive|Teams|msteams|XblGrts))|SSO_POP_User|^Microsoft_OneDrive|virtualapp/'
        $useful = @($creds | Where-Object { $_.Target -notmatch $appNoise })
        $hidden = $creds.Count - $useful.Count
        foreach ($c in $useful) {
            $label = "Credential: $($c.Target)"
            $who = if ($c.User) { $c.User } else { '(no user name)' }
            Add-MaResult $Results $cat $label 'Warning' "Re-enter password for $who (Windows does not allow exporting saved passwords)."
        }
        if ($hidden -gt 0) {
            Add-MaResult $Results $cat 'App sign-in tokens' 'Skipped' ("{0} app-managed entries (Microsoft account, OneDrive, Adobe, 1Password, Outlook) not listed; the apps recreate them at sign-in." -f $hidden)
        }
    }
}

# ---------------------------------------------------------------------------
# Category: Wi-Fi and network
# ---------------------------------------------------------------------------

function Export-MaWifiNetwork {
    param([string]$Bundle, [string]$SecretsDir, [System.Collections.ArrayList]$Results, [bool]$IncludeWifiProfiles = $true)
    $cat = 'WifiNetwork'
    $dir = Join-Path $Bundle 'WifiNetwork'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # Wi-Fi profiles with keys in clear text -> encrypted secrets only. Opt-in in the UI: 'netsh wlan export
    # profile key=clear' is a known credential-access pattern for EDR products.
    if ($IncludeWifiProfiles) {
        $wifiDir = Join-Path $SecretsDir 'Wifi'
        New-Item -ItemType Directory -Path $wifiDir -Force | Out-Null
        $out = (& netsh.exe wlan export profile key=clear folder="$wifiDir" 2>&1) | Out-String
        $files = @(Get-ChildItem $wifiDir -Filter '*.xml' -ErrorAction SilentlyContinue)
        if ($files.Count -gt 0) {
            foreach ($f in $files) { Add-MaResult $Results $cat ("Wi-Fi: " + $f.BaseName) 'OK' 'Exported (key stored encrypted).' }
        } else {
            Add-MaResult $Results $cat 'Wi-Fi profiles' 'Skipped' 'None found (or no WLAN service).'
        }
    } else {
        Add-MaResult $Results $cat 'Wi-Fi profiles' 'Skipped' 'Not selected (Include Wi-Fi profiles and saved passwords).'
    }

    # Static IP configuration
    $adapters = @()
    foreach ($ifc in (Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.Dhcp -eq 'Disabled' })) {
        $na = Get-NetAdapter -InterfaceIndex $ifc.InterfaceIndex -Physical -ErrorAction SilentlyContinue
        if (-not $na) { continue }
        $ips = @(Get-NetIPAddress -InterfaceIndex $ifc.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -eq 'Manual' })
        if ($ips.Count -eq 0) { continue }
        $gw = (Get-NetRoute -InterfaceIndex $ifc.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        $dns = @((Get-DnsClientServerAddress -InterfaceIndex $ifc.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        $adapters += [pscustomobject]@{
            Name     = $na.Name
            Mac      = $na.MacAddress
            Address  = @($ips | ForEach-Object { [pscustomobject]@{ IP = $_.IPAddress; Prefix = $_.PrefixLength } })
            Gateway  = $gw
            Dns      = $dns
        }
        Add-MaResult $Results $cat ("Static IP: " + $na.Name) 'OK' (($ips | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', ')
    }
    Save-MaJson $adapters (Join-Path $dir 'static-ip.json')
    if ($adapters.Count -eq 0) { Add-MaResult $Results $cat 'Static IP' 'Skipped' 'All physical adapters use DHCP.' }

    # Proxy
    try {
        $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        $proxy = [pscustomobject]@{
            ProxyEnable   = $ie.ProxyEnable
            ProxyServer   = $ie.ProxyServer
            ProxyOverride = $ie.ProxyOverride
            AutoConfigURL = $ie.AutoConfigURL
        }
        Save-MaJson $proxy (Join-Path $dir 'proxy.json')
        $winhttp = (& netsh.exe winhttp show proxy 2>&1) | Out-String
        Set-Content -Path (Join-Path $dir 'winhttp-proxy.txt') -Value $winhttp -Encoding UTF8
        Add-MaResult $Results $cat 'Proxy' 'OK' 'WinINET settings saved; WinHTTP saved for reference.'
    } catch {
        Add-MaResult $Results $cat 'Proxy' 'Warning' $_.Exception.Message
    }

    # hosts file
    $hosts = Join-Path $env:windir 'System32\drivers\etc\hosts'
    if (Test-Path $hosts) {
        Copy-Item $hosts (Join-Path $dir 'hosts') -Force
        Add-MaResult $Results $cat 'hosts file' 'OK' ''
    }

    # VPN connections
    $vpn = @()
    foreach ($all in $false, $true) {
        try {
            $conns = if ($all) { Get-VpnConnection -AllUserConnection -ErrorAction Stop } else { Get-VpnConnection -ErrorAction Stop }
            foreach ($v in @($conns)) {
                $vpn += [pscustomobject]@{
                    Name                 = $v.Name
                    ServerAddress        = $v.ServerAddress
                    TunnelType           = [string]$v.TunnelType
                    AuthenticationMethod = @($v.AuthenticationMethod | ForEach-Object { [string]$_ })
                    SplitTunneling       = [bool]$v.SplitTunneling
                    RememberCredential   = [bool]$v.RememberCredential
                    AllUsers             = $all
                }
                Add-MaResult $Results $cat ("VPN: " + $v.Name) 'OK' $v.ServerAddress
            }
        } catch { }
    }
    Save-MaJson $vpn (Join-Path $dir 'vpn.json')
}

function Import-MaWifiNetwork {
    param([string]$Bundle, [string]$SecretsDir, [System.Collections.ArrayList]$Results, [bool]$Preview, [bool]$RestoreStaticIp)
    $cat = 'WifiNetwork'
    $dir = Join-Path $Bundle 'WifiNetwork'
    if (-not (Test-Path $dir)) {
        Add-MaResult $Results $cat 'Wi-Fi and network' 'Skipped' 'Not present in bundle.'
        return
    }

    # Wi-Fi
    $wifiDir = Join-Path $SecretsDir 'Wifi'
    if (Test-Path $wifiDir) {
        $existing = @()
        foreach ($line in ((& netsh.exe wlan show profiles 2>&1) | Out-String) -split "`r?`n") {
            if ($line -match 'All User Profile\s*:\s*(.+)$') { $existing += $Matches[1].Trim() }
        }
        foreach ($f in (Get-ChildItem $wifiDir -Filter '*.xml' -ErrorAction SilentlyContinue)) {
            $name = $f.BaseName -replace '^Wi-Fi-', ''
            $item = "Wi-Fi: $name"
            if ($existing -contains $name) {
                Add-MaResult $Results $cat $item $(if ($Preview) { 'Preview' } else { 'Skipped' }) 'Profile already exists.'
                continue
            }
            if ($Preview) { Add-MaResult $Results $cat $item 'Preview' 'Would add profile.'; continue }
            $o = ((& netsh.exe wlan add profile filename="$($f.FullName)" user=all 2>&1) | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) { Add-MaResult $Results $cat $item 'OK' '' } else { Add-MaResult $Results $cat $item 'Failed' $o }
        }
    }

    # Static IP (opt-in)
    $adapters = Read-MaJson (Join-Path $dir 'static-ip.json')
    foreach ($a in $adapters) {
        $item = "Static IP: $($a.Name)"
        if (-not $RestoreStaticIp) {
            Add-MaResult $Results $cat $item 'Skipped' 'Static IP restore not selected.'
            continue
        }
        try {
            $na = Get-NetAdapter -Name $a.Name -Physical -ErrorAction SilentlyContinue
            if (-not $na) { $na = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.MacAddress -eq $a.Mac } | Select-Object -First 1 }
            if (-not $na) { Add-MaResult $Results $cat $item 'Warning' 'No matching adapter on this PC.'; continue }
            if ($Preview) { Add-MaResult $Results $cat $item 'Preview' "Would set static IP on $($na.Name)."; continue }
            $first = $true
            foreach ($ip in @($a.Address)) {
                if ($first -and $a.Gateway) {
                    New-NetIPAddress -InterfaceIndex $na.ifIndex -IPAddress $ip.IP -PrefixLength $ip.Prefix -DefaultGateway $a.Gateway -ErrorAction Stop | Out-Null
                } else {
                    New-NetIPAddress -InterfaceIndex $na.ifIndex -IPAddress $ip.IP -PrefixLength $ip.Prefix -ErrorAction Stop | Out-Null
                }
                $first = $false
            }
            if ($a.Dns) { Set-DnsClientServerAddress -InterfaceIndex $na.ifIndex -ServerAddresses @($a.Dns) -ErrorAction Stop }
            Add-MaResult $Results $cat $item 'OK' 'Applied. Verify connectivity - the subnet may differ on this network.'
        } catch {
            Add-MaResult $Results $cat $item 'Failed' $_.Exception.Message
        }
    }

    # Proxy
    $proxyFile = Join-Path $dir 'proxy.json'
    if (Test-Path $proxyFile) {
        $px = (Read-MaJson $proxyFile) | Select-Object -First 1
        if ($px) {
            if ($Preview) {
                Add-MaResult $Results $cat 'Proxy' 'Preview' 'Would apply WinINET proxy settings.'
            } else {
                try {
                    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                    if ($null -ne $px.ProxyEnable) { Set-ItemProperty -Path $key -Name ProxyEnable -Value ([int]$px.ProxyEnable) -ErrorAction Stop }
                    if ($px.ProxyServer) { Set-ItemProperty -Path $key -Name ProxyServer -Value ([string]$px.ProxyServer) -ErrorAction Stop }
                    if ($px.ProxyOverride) { Set-ItemProperty -Path $key -Name ProxyOverride -Value ([string]$px.ProxyOverride) -ErrorAction Stop }
                    if ($px.AutoConfigURL) { Set-ItemProperty -Path $key -Name AutoConfigURL -Value ([string]$px.AutoConfigURL) -ErrorAction Stop }
                    Add-MaResult $Results $cat 'Proxy' 'OK' 'WinINET settings applied (WinHTTP not changed).'
                } catch {
                    Add-MaResult $Results $cat 'Proxy' 'Failed' $_.Exception.Message
                }
            }
        }
    }

    # hosts file: append missing entries only
    $srcHosts = Join-Path $dir 'hosts'
    if (Test-Path $srcHosts) {
        $dstHosts = Join-Path $env:windir 'System32\drivers\etc\hosts'
        $have = @(Get-Content $dstHosts -ErrorAction SilentlyContinue | ForEach-Object { ($_ -replace '\s+', ' ').Trim() })
        $new = @()
        foreach ($line in (Get-Content $srcHosts)) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            $norm = ($t -replace '\s+', ' ')
            if ($have -notcontains $norm) { $new += $t }
        }
        if ($new.Count -eq 0) {
            Add-MaResult $Results $cat 'hosts file' 'Skipped' 'No new entries.'
        } elseif ($Preview) {
            Add-MaResult $Results $cat 'hosts file' 'Preview' ("Would append {0} entries." -f $new.Count)
        } else {
            try {
                Add-Content -Path $dstHosts -Value $new -ErrorAction Stop
                Add-MaResult $Results $cat 'hosts file' 'OK' ("Appended {0} entries." -f $new.Count)
            } catch {
                Add-MaResult $Results $cat 'hosts file' 'Failed' $_.Exception.Message
            }
        }
    }

    # VPN
    foreach ($v in (Read-MaJson (Join-Path $dir 'vpn.json'))) {
        $item = "VPN: $($v.Name)"
        try {
            $args2 = @{ Name = $v.Name }
            if ($v.AllUsers) { $args2.AllUserConnection = $true }
            if (Get-VpnConnection @args2 -ErrorAction SilentlyContinue) {
                Add-MaResult $Results $cat $item $(if ($Preview) { 'Preview' } else { 'Skipped' }) 'Already exists.'
                continue
            }
            if ($Preview) { Add-MaResult $Results $cat $item 'Preview' 'Would create.'; continue }
            $add = @{
                Name = $v.Name; ServerAddress = $v.ServerAddress; TunnelType = $v.TunnelType
                SplitTunneling = [bool]$v.SplitTunneling; RememberCredential = [bool]$v.RememberCredential
                PassThru = $true
            }
            if ($v.AllUsers) { $add.AllUserConnection = $true }
            $am = @($v.AuthenticationMethod) | Select-Object -First 1
            if ($am) { $add.AuthenticationMethod = $am }
            Add-VpnConnection @add -ErrorAction Stop | Out-Null
            Add-MaResult $Results $cat $item 'OK' 'Created. Re-enter VPN credentials/certificates if required.'
        } catch {
            Add-MaResult $Results $cat $item 'Failed' $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Category: System settings
# ---------------------------------------------------------------------------

function Export-MaSystemSettings {
    param([string]$Bundle, [System.Collections.ArrayList]$Results)
    $cat = 'SystemSettings'
    $dir = Join-Path $Bundle 'SystemSettings'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # Installed software
    try {
        $keys = @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $sw = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
            Select-Object DisplayName, DisplayVersion, Publisher |
            Sort-Object DisplayName -Unique
        $sw | Export-Csv -Path (Join-Path $dir 'installed-software.csv') -NoTypeInformation -Encoding UTF8
        Add-MaResult $Results $cat 'Installed software' 'OK' ("{0} entries" -f @($sw).Count)
    } catch {
        Add-MaResult $Results $cat 'Installed software' 'Failed' $_.Exception.Message
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        $r = Invoke-MaProcess -FilePath $winget.Source -Arguments ('export -o "{0}" --accept-source-agreements --disable-interactivity' -f (Join-Path $dir 'winget-export.json')) -TimeoutSec 120
        if (Test-Path (Join-Path $dir 'winget-export.json')) {
            Add-MaResult $Results $cat 'winget export' 'OK' 'winget-export.json (usable with winget import)'
        } else {
            Add-MaResult $Results $cat 'winget export' 'Warning' 'winget did not produce an export; skipped.'
        }
    }

    # Environment variables
    try {
        $skip = '^(Path|PATHEXT|PSModulePath|TEMP|TMP|ComSpec|windir|SystemRoot|OS|PROCESSOR_.*|NUMBER_OF_PROCESSORS|USERNAME|USERPROFILE|DriverData|OneDrive.*|POWERSHELL_DISTRIBUTION_CHANNEL|ZES_ENABLE_SYSMAN|NPU_.*|CUDA_.*)$'
        $envRows = @()
        foreach ($scope in 'Machine', 'User') {
            $vars = [Environment]::GetEnvironmentVariables($scope)
            foreach ($k in $vars.Keys) {
                if ($k -match $skip) { continue }
                $envRows += [pscustomobject]@{ Scope = $scope; Name = [string]$k; Value = [string]$vars[$k] }
            }
        }
        Save-MaJson $envRows (Join-Path $dir 'environment.json')
        Add-MaResult $Results $cat 'Environment variables' 'OK' ("{0} variables (Path excluded)" -f $envRows.Count)
    } catch {
        Add-MaResult $Results $cat 'Environment variables' 'Failed' $_.Exception.Message
    }

    # Default apps
    $r = Invoke-MaProcess -FilePath "$env:windir\System32\dism.exe" -Arguments ('/Online /Export-DefaultAppAssociations:"{0}"' -f (Join-Path $dir 'default-apps.xml')) -TimeoutSec 120
    if (Test-Path (Join-Path $dir 'default-apps.xml')) {
        Add-MaResult $Results $cat 'Default apps' 'OK' ''
    } else {
        Add-MaResult $Results $cat 'Default apps' 'Warning' ("dism exit code {0}" -f $r.ExitCode)
    }

    # Scheduled tasks (non-Microsoft)
    try {
        $taskDir = Join-Path $dir 'ScheduledTasks'
        New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
        # Vendor updaters, agents and per-user helpers are recreated by their installers and
        # often run as account SIDs that do not exist on another install, so they are skipped.
        $skipTasks = '(OneDrive|MicrosoftEdgeUpdate|GoogleUpdate|Update|Updater|AutoUpdate|Self-?heal|AutoRepair|Adobe|User_Feed_Synchronization|Opera|CCleaner|npcap|Optimize Start Menu|ShadowCopy|Dell|ITSPlatform|Zoom|Firefox|Vivaldi|Scribe|RunPlatformExperience|SoftLanding|Autorun for|Brave|Chrome|Edge|Teams|Slack|Dropbox|Intel|NVIDIA|HP |Lenovo)'
        $portablePrincipal = '^(SYSTEM|NT AUTHORITY\\SYSTEM|LOCAL SERVICE|NETWORK SERVICE|NT AUTHORITY\\.+|S-1-5-(18|19|20)|BUILTIN\\Administrators|Administrators|S-1-5-32-544)$'
        $all = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })
        $tasks = @()
        foreach ($t in $all) {
            $uid = [string]$t.Principal.UserId
            if ($t.TaskName -match $skipTasks) {
                Add-MaResult $Results $cat ("Task: " + $t.TaskName) 'Skipped' 'Vendor updater/agent or per-user helper; recreated by its installer.'
            } elseif ($uid -and $uid -notmatch $portablePrincipal) {
                Add-MaResult $Results $cat ("Task: " + $t.TaskName) 'Skipped' ("Runs as '{0}', a user account that may not exist on the new install. Recreate manually if needed." -f $uid)
            } else {
                $tasks += $t
            }
        }
        $rows = @()
        $i = 0
        foreach ($t in $tasks) {
            $i++
            $file = '{0:D3}_{1}.xml' -f $i, (Get-MaSafeName $t.TaskName)
            try {
                Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-File -FilePath (Join-Path $taskDir $file) -Encoding Unicode
                $rows += [pscustomobject]@{
                    TaskName = $t.TaskName
                    TaskPath = $t.TaskPath
                    File     = $file
                    RunAs    = [string]$t.Principal.UserId
                    Logon    = [string]$t.Principal.LogonType
                }
                Add-MaResult $Results $cat ("Task: " + $t.TaskName) 'OK' ("runs as {0}" -f $t.Principal.UserId)
            } catch {
                Add-MaResult $Results $cat ("Task: " + $t.TaskName) 'Failed' $_.Exception.Message
            }
        }
        Save-MaJson $rows (Join-Path $taskDir 'tasks.json')
        if ($tasks.Count -eq 0) { Add-MaResult $Results $cat 'Scheduled tasks' 'Skipped' 'No third-party tasks.' }
    } catch {
        Add-MaResult $Results $cat 'Scheduled tasks' 'Failed' $_.Exception.Message
    }

    # Certificates (public part only)
    try {
        $certDir = Join-Path $dir 'Certificates'
        New-Item -ItemType Directory -Path $certDir -Force | Out-Null
        $certRows = @()
        foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My') {
            foreach ($c in (Get-ChildItem $store -ErrorAction SilentlyContinue)) {
                # Device/identity certificates (Azure AD join, device trust, self-signed GUIDs) belong to
                # this specific install and are recreated by joining/signing in; skip them.
                if ($c.Subject -match 'S-1-12-1-|^CN=trust_|^CN=[0-9a-fA-F-]{36}(,|$)|^CN=localhost$' -or
                    $c.Issuer -match 'MS-Organization|Microsoft Intune|Windows Hello|Microsoft Azure|^CN=Microsoft') {
                    continue
                }
                $file = '{0}.cer' -f $c.Thumbprint
                Export-Certificate -Cert $c -FilePath (Join-Path $certDir $file) -Type CERT -Force -ErrorAction Stop | Out-Null
                $certRows += [pscustomobject]@{
                    Store = $store; Subject = $c.Subject; Thumbprint = $c.Thumbprint
                    HasPrivateKey = [bool]$c.HasPrivateKey; File = $file
                }
                $note = 'public certificate only'
                if ($c.HasPrivateKey) { $note = 'public certificate only; PRIVATE KEY NOT EXPORTED' }
                Add-MaResult $Results $cat ("Cert: " + $c.Subject) $(if ($c.HasPrivateKey) { 'Warning' } else { 'OK' }) $note
            }
        }
        Save-MaJson $certRows (Join-Path $certDir 'certs.json')
    } catch {
        Add-MaResult $Results $cat 'Certificates' 'Failed' $_.Exception.Message
    }

    # Time zone and regional
    try {
        $reg = [pscustomobject]@{
            TimeZoneId = (Get-TimeZone).Id
            Culture    = (Get-Culture).Name
            GeoId      = $null
        }
        try { $reg.GeoId = (Get-WinHomeLocation).GeoId } catch { }
        Save-MaJson $reg (Join-Path $dir 'regional.json')
        Add-MaResult $Results $cat 'Time zone and region' 'OK' ("{0}, {1}" -f $reg.TimeZoneId, $reg.Culture)
    } catch {
        Add-MaResult $Results $cat 'Time zone and region' 'Failed' $_.Exception.Message
    }
}

function Import-MaSystemSettings {
    param([string]$Bundle, [System.Collections.ArrayList]$Results, [bool]$Preview)
    $cat = 'SystemSettings'
    $dir = Join-Path $Bundle 'SystemSettings'
    if (-not (Test-Path $dir)) {
        Add-MaResult $Results $cat 'System settings' 'Skipped' 'Not present in bundle.'
        return
    }

    if (Test-Path (Join-Path $dir 'installed-software.csv')) {
        Add-MaResult $Results $cat 'Installed software' 'Skipped' 'Reference list only (installed-software.csv / winget-export.json in the bundle). Use the Software Manager or winget import to reinstall.'
    }

    # Environment variables (set missing only)
    foreach ($e in (Read-MaJson (Join-Path $dir 'environment.json'))) {
        $item = "Env ($($e.Scope)): $($e.Name)"
        try {
            $cur = [Environment]::GetEnvironmentVariable($e.Name, $e.Scope)
            if ($null -ne $cur) { Add-MaResult $Results $cat $item $(if ($Preview) { 'Preview' } else { 'Skipped' }) 'Already set.'; continue }
            if ($Preview) { Add-MaResult $Results $cat $item 'Preview' 'Would set.'; continue }
            [Environment]::SetEnvironmentVariable($e.Name, $e.Value, $e.Scope)
            Add-MaResult $Results $cat $item 'OK' ''
        } catch {
            Add-MaResult $Results $cat $item 'Failed' $_.Exception.Message
        }
    }

    # Default apps
    $apps = Join-Path $dir 'default-apps.xml'
    if (Test-Path $apps) {
        if ($Preview) {
            Add-MaResult $Results $cat 'Default apps' 'Preview' 'Would import default app associations (applies to new user profiles).'
        } else {
            $r = Invoke-MaProcess -FilePath "$env:windir\System32\dism.exe" -Arguments ('/Online /Import-DefaultAppAssociations:"{0}"' -f $apps) -TimeoutSec 120
            if ($r.ExitCode -eq 0) { Add-MaResult $Results $cat 'Default apps' 'OK' 'Applies to profiles created after this point.' }
            else { Add-MaResult $Results $cat 'Default apps' 'Failed' ("dism exit code {0}" -f $r.ExitCode) }
        }
    }

    # Scheduled tasks
    $taskDir = Join-Path $dir 'ScheduledTasks'
    foreach ($t in (Read-MaJson (Join-Path $taskDir 'tasks.json'))) {
        $item = "Task: $($t.TaskName)"
        try {
            if (Get-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue) {
                Add-MaResult $Results $cat $item $(if ($Preview) { 'Preview' } else { 'Skipped' }) 'Already exists.'
                continue
            }
            if ($Preview) { Add-MaResult $Results $cat $item 'Preview' "Would register (runs as $($t.RunAs))."; continue }
            $xml = Get-Content -Path (Join-Path $taskDir $t.File) -Raw
            Register-ScheduledTask -Xml $xml -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
            Add-MaResult $Results $cat $item 'OK' ("Registered (runs as {0})." -f $t.RunAs)
        } catch {
            $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
            Add-MaResult $Results $cat $item 'Failed' ($msg + " (a task that runs as a specific user needs that account to exist.)")
        }
    }

    # Certificates
    $certDir = Join-Path $dir 'Certificates'
    foreach ($c in (Read-MaJson (Join-Path $certDir 'certs.json'))) {
        $item = "Cert: $($c.Subject)"
        try {
            $store = $c.Store
            if (Test-Path (Join-Path $store $c.Thumbprint)) {
                Add-MaResult $Results $cat $item $(if ($Preview) { 'Preview' } else { 'Skipped' }) 'Already present.'
                continue
            }
            if ($Preview) { Add-MaResult $Results $cat $item 'Preview' 'Would import public certificate.'; continue }
            Import-Certificate -FilePath (Join-Path $certDir $c.File) -CertStoreLocation $store -ErrorAction Stop | Out-Null
            $detail = 'Imported public certificate.'
            if ($c.HasPrivateKey) { $detail += ' Private key was not migrated; re-issue or re-import the PFX.' }
            Add-MaResult $Results $cat $item $(if ($c.HasPrivateKey) { 'Warning' } else { 'OK' }) $detail
        } catch {
            Add-MaResult $Results $cat $item 'Failed' $_.Exception.Message
        }
    }

    # Time zone and region
    $regFile = Join-Path $dir 'regional.json'
    if (Test-Path $regFile) {
        $reg = (Read-MaJson $regFile) | Select-Object -First 1
        if ($Preview) {
            Add-MaResult $Results $cat 'Time zone and region' 'Preview' ("Would set {0}, {1}" -f $reg.TimeZoneId, $reg.Culture)
        } else {
            try {
                if ($reg.TimeZoneId) { Set-TimeZone -Id $reg.TimeZoneId -ErrorAction Stop }
                if ($reg.Culture) { Set-Culture -CultureInfo $reg.Culture -ErrorAction Stop }
                if ($reg.GeoId) { Set-WinHomeLocation -GeoId ([int]$reg.GeoId) -ErrorAction Stop }
                Add-MaResult $Results $cat 'Time zone and region' 'OK' ("{0}, {1}" -f $reg.TimeZoneId, $reg.Culture)
            } catch {
                Add-MaResult $Results $cat 'Time zone and region' 'Failed' $_.Exception.Message
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Get-MaSummary {
    param([System.Collections.ArrayList]$Results)
    $ok = @($Results | Where-Object { $_.Status -eq 'OK' }).Count
    $warn = @($Results | Where-Object { $_.Status -eq 'Warning' }).Count
    $fail = @($Results | Where-Object { $_.Status -eq 'Failed' }).Count
    $skip = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count
    $prev = @($Results | Where-Object { $_.Status -eq 'Preview' }).Count
    return [pscustomobject]@{ Ok = $ok; Warnings = $warn; Failed = $fail; Skipped = $skip; Preview = $prev }
}

function Write-MaReport {
    param([string]$Mode, [System.Collections.ArrayList]$Results, [string]$BundlePath)
    $outDir = Get-ToolkitInfoPath -Module 'MigrationAssist'   # C:\_INFO\MigrationAssist, refused if it is a link
    $file = Join-Path $outDir ("Migration_{0}_{1}_{2}.txt" -f $Mode, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
    $lines = New-Object System.Collections.ArrayList
    $lines.Add("Migration Assist - $Mode") | Out-Null
    $lines.Add("Computer: $env:COMPUTERNAME   User: $env:USERNAME   Date: $(Get-Date)") | Out-Null
    $lines.Add("Bundle:   $BundlePath") | Out-Null
    $lines.Add('') | Out-Null
    foreach ($r in $Results) {
        $l = "[{0}] {1} - {2}" -f $r.Category, $r.Item, $r.Status
        if ($r.Detail) { $l += ": " + $r.Detail }
        $lines.Add($l) | Out-Null
    }
    Set-Content -Path $file -Value $lines -Encoding UTF8
    return $file
}

function Invoke-MigrationExport {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Categories = @('Printers', 'NetworkDrives', 'WifiNetwork', 'SystemSettings'),
        [string]$Passphrase,
        [bool]$IncludeDriverPackages = $true,
        [bool]$IncludeWifiProfiles = $true
    )
    Assert-MaAdmin
    # secrets.enc (Wi-Fi keys, drive credentials) travels on USB sticks and shares: guessable offline
    if (-not $Passphrase -or $Passphrase.Length -lt 8) { throw 'A passphrase of at least 8 characters is required.' }
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $bundle = Join-Path $Destination ("Migration_{0}_{1}" -f $env:COMPUTERNAME, $stamp)
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    # Plaintext secrets live here until encrypted: private from creation (TEMP may be the shared C:\Windows\Temp)
    $secrets = New-ToolkitPrivateDirectory -Path (Join-Path $env:TEMP ('MaSecrets_' + [guid]::NewGuid().ToString('N')))

    $results = New-Object System.Collections.ArrayList
    $secretsFile = $false
    try {
        Write-MaLog "Export started -> $bundle"
        foreach ($c in $Categories) {
            try {
                switch ($c) {
                    'Printers'       { Export-MaPrinters -Bundle $bundle -Results $results -IncludeDriverPackages $IncludeDriverPackages }
                    'NetworkDrives'  { Export-MaNetworkDrives -Bundle $bundle -SecretsDir $secrets -Results $results }
                    'WifiNetwork'    { Export-MaWifiNetwork -Bundle $bundle -SecretsDir $secrets -Results $results -IncludeWifiProfiles $IncludeWifiProfiles }
                    'SystemSettings' { Export-MaSystemSettings -Bundle $bundle -Results $results }
                }
            } catch {
                Add-MaResult $results $c 'Category' 'Failed' $_.Exception.Message
            }
        }

        if (@(Get-ChildItem $secrets -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) {
            Protect-MigrationSecrets -SourceDir $secrets -OutFile (Join-Path $bundle 'secrets.enc') -Passphrase $Passphrase
            $secretsFile = $true
            Write-MaLog 'Secrets encrypted to secrets.enc' 'Success'
        }

        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $ver = ''
        if ($Global:SyncHash -and $Global:SyncHash.Toolkit) { $ver = [string]$Global:SyncHash.Toolkit.Version }
        $manifest = [pscustomobject]@{
            SourceComputer = $env:COMPUTERNAME
            SourceUser     = $env:USERNAME
            ExportedAt     = (Get-Date).ToString('s')
            OS             = $os.Caption
            OSVersion      = $os.Version
            Architecture   = $os.OSArchitecture
            ToolkitVersion = $ver
            Categories     = @($Categories)
            HasSecrets     = $secretsFile
            Results        = @($results)
        }
        Save-MaJson $manifest (Join-Path $bundle 'manifest.json')
    } finally {
        Remove-ToolkitTree -LiteralPath $secrets
        $Passphrase = $null
    }

    $report = Write-MaReport -Mode 'Export' -Results $results -BundlePath $bundle
    $sum = Get-MaSummary $results
    Write-MaLog ("Export finished: {0} ok, {1} warnings, {2} failed. Report: {3}" -f $sum.Ok, $sum.Warnings, $sum.Failed, $report) 'Success'
    return [pscustomobject]@{ Bundle = $bundle; Report = $report; Summary = $sum }
}

function Find-MaBundle {
    param([string]$Path)
    if (Test-Path (Join-Path $Path 'manifest.json')) { return $Path }
    $child = Get-ChildItem $Path -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($child) { return $child.FullName }
    return $null
}

function Invoke-MigrationImport {
    param(
        [Parameter(Mandatory)][string]$Bundle,
        [string[]]$Categories = @('Printers', 'NetworkDrives', 'WifiNetwork', 'SystemSettings'),
        [string]$Passphrase,
        [bool]$Preview = $true,
        [bool]$RestoreStaticIp = $false,
        [bool]$Overwrite = $false
    )
    Assert-MaAdmin
    $found = Find-MaBundle $Bundle
    if (-not $found) { throw "No manifest.json found in '$Bundle'. Select the Migration_* bundle folder." }
    $Bundle = $found
    $manifest = (Read-MaJson (Join-Path $Bundle 'manifest.json')) | Select-Object -First 1

    $results = New-Object System.Collections.ArrayList
    $mode = 'Import'
    if ($Preview) { $mode = 'Preview' }
    Write-MaLog "$mode started from $Bundle (exported from $($manifest.SourceComputer) on $($manifest.ExportedAt))"

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($manifest.Architecture -and $os.OSArchitecture -ne $manifest.Architecture) {
        Write-MaLog "Architecture differs (bundle: $($manifest.Architecture), this PC: $($os.OSArchitecture)). Printer drivers will likely not install." 'Warning'
    }

    $secrets = Join-Path $env:TEMP ('MaSecrets_' + [guid]::NewGuid().ToString('N'))
    try {
        # Decrypted secrets land here: private from creation (TEMP may be the shared C:\Windows\Temp)
        $secrets = New-ToolkitPrivateDirectory -Path $secrets
        $encFile = Join-Path $Bundle 'secrets.enc'
        $needSecrets = (@($Categories) -contains 'NetworkDrives') -or (@($Categories) -contains 'WifiNetwork')
        if ($needSecrets -and (Test-Path $encFile)) {
            if (-not $Passphrase) { throw 'This bundle has encrypted secrets; enter the passphrase.' }
            Unprotect-MigrationSecrets -File $encFile -DestDir $secrets -Passphrase $Passphrase
            Write-MaLog 'Secrets decrypted.' 'Success'
        }

        foreach ($c in $Categories) {
            try {
                switch ($c) {
                    'Printers'       { Import-MaPrinters -Bundle $Bundle -Results $results -Preview $Preview -Overwrite $Overwrite }
                    'NetworkDrives'  { Import-MaNetworkDrives -Bundle $Bundle -SecretsDir $secrets -Results $results -Preview $Preview }
                    'WifiNetwork'    { Import-MaWifiNetwork -Bundle $Bundle -SecretsDir $secrets -Results $results -Preview $Preview -RestoreStaticIp $RestoreStaticIp }
                    'SystemSettings' { Import-MaSystemSettings -Bundle $Bundle -Results $results -Preview $Preview }
                }
            } catch {
                Add-MaResult $results $c 'Category' 'Failed' $_.Exception.Message
            }
        }
    } finally {
        Remove-ToolkitTree -LiteralPath $secrets
        $Passphrase = $null
    }

    $report = Write-MaReport -Mode $mode -Results $results -BundlePath $Bundle
    $sum = Get-MaSummary $results
    Write-MaLog ("{0} finished: {1} ok, {2} warnings, {3} failed, {4} preview. Report: {5}" -f $mode, $sum.Ok, $sum.Warnings, $sum.Failed, $sum.Preview, $report) 'Success'
    return [pscustomobject]@{ Bundle = $Bundle; Report = $report; Summary = $sum; Preview = $Preview }
}

function Start-MigrationAssist {
    # Default entry point (used only if the panel is not shown): exports are driven from the UI
    # because a passphrase is required.
    Write-MaLog 'Open the Migration Assist panel to run an export or import (a passphrase is required).' 'Info'
}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

function New-MaBrush {
    param([string]$Hex)
    New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

function New-MaText {
    param([string]$Text, [int]$Size = 13, $Brush, [bool]$Bold = $false, $Margin)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = $Brush
    $t.TextWrapping = 'Wrap'
    if ($Bold) { $t.FontWeight = 'Bold' }
    if ($Margin) { $t.Margin = $Margin }
    return $t
}

function New-MaCheck {
    param([string]$Text, [bool]$Checked, $Brush)
    $c = New-Object System.Windows.Controls.CheckBox
    $c.Content = $Text
    $c.IsChecked = $Checked
    $c.Foreground = $Brush
    $c.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    return $c
}

function New-MaPathRow {
    param($Brush, $InputBg, $InputBorder)
    $row = New-Object System.Windows.Controls.DockPanel
    $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = 'Browse...'
    $btn.Padding = [System.Windows.Thickness]::new(12, 5, 12, 5)
    $btn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
    $row.Children.Add($btn) | Out-Null
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Padding = [System.Windows.Thickness]::new(6, 4, 6, 4)
    $tb.Foreground = $Brush
    $tb.Background = $InputBg
    $tb.BorderBrush = $InputBorder
    $row.Children.Add($tb) | Out-Null
    return @{ Row = $row; Box = $tb; Button = $btn }
}

function New-MaPasswordBox {
    param($Brush, $InputBg, $InputBorder)
    $pb = New-Object System.Windows.Controls.PasswordBox
    $pb.Padding = [System.Windows.Thickness]::new(6, 4, 6, 4)
    $pb.Foreground = $Brush
    $pb.Background = $InputBg
    $pb.BorderBrush = $InputBorder
    $pb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    return $pb
}

function Get-MigrationAssistUI {
    $accent = New-MaBrush (Get-ToolkitAccent)
    $dim = New-MaBrush '#A6ADC8'
    $text = New-MaBrush '#CDD6F4'
    $dark = New-MaBrush '#1E1E2E'
    $inputBg = New-MaBrush '#313244'
    $inputBorder = New-MaBrush '#45475A'

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)

    $panel.Children.Add((New-MaText 'Migration Assist' 22 $accent $true ([System.Windows.Thickness]::new(0, 0, 0, 6)))) | Out-Null
    $panel.Children.Add((New-MaText 'Move printers (with drivers), mapped drives, Wi-Fi/network settings and system settings between Windows installs. Export on the old install to a bundle folder (USB or share), then import on the new one. Run as the user who owns the drives and printers.' 13 $dim $false ([System.Windows.Thickness]::new(0, 0, 0, 20)))) | Out-Null

    # ---- Export ----
    $panel.Children.Add((New-MaText 'EXPORT (old install)' 13 $text $true ([System.Windows.Thickness]::new(0, 0, 0, 8)))) | Out-Null
    $expPrinters = New-MaCheck 'Printers (queues, ports, PrintBrm backup)' $true $text
    $expDrivers = New-MaCheck 'Include printer driver packages' $true $text
    $expDrivers.Margin = [System.Windows.Thickness]::new(20, 0, 0, 4)
    $expDrives = New-MaCheck 'Network drives and saved credential names' $true $text
    $expWifi = New-MaCheck 'Network settings (static IP, proxy, hosts file, VPN)' $true $text
    # Off by default: exporting saved Wi-Fi passwords ('netsh wlan export profile key=clear') is a pattern EDR products flag
    $expWifiKeys = New-MaCheck 'Include Wi-Fi profiles and saved Wi-Fi passwords' $false $text
    $expWifiKeys.Margin = [System.Windows.Thickness]::new(20, 0, 0, 4)
    $expSys = New-MaCheck 'System settings (software list, env vars, default apps, tasks, certs, region)' $true $text
    foreach ($c in $expPrinters, $expDrivers, $expDrives, $expWifi, $expWifiKeys, $expSys) { $panel.Children.Add($c) | Out-Null }

    $panel.Children.Add((New-MaText 'Save bundle to:' 12 $dim $false ([System.Windows.Thickness]::new(0, 8, 0, 4)))) | Out-Null
    $expPath = New-MaPathRow $text $inputBg $inputBorder
    $panel.Children.Add($expPath.Row) | Out-Null
    $panel.Children.Add((New-MaText 'Passphrase (encrypts Wi-Fi keys and credential names):' 12 $dim $false ([System.Windows.Thickness]::new(0, 0, 0, 4)))) | Out-Null
    $expPass = New-MaPasswordBox $text $inputBg $inputBorder
    $panel.Children.Add($expPass) | Out-Null
    $panel.Children.Add((New-MaText 'Confirm passphrase:' 12 $dim $false ([System.Windows.Thickness]::new(0, 0, 0, 4)))) | Out-Null
    $expPass2 = New-MaPasswordBox $text $inputBg $inputBorder
    $panel.Children.Add($expPass2) | Out-Null

    $exportBtn = New-Object System.Windows.Controls.Button
    $exportBtn.Content = 'Export'
    $exportBtn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $exportBtn.FontWeight = 'Bold'
    $exportBtn.Background = $accent
    $exportBtn.Foreground = $dark
    $exportBtn.HorizontalAlignment = 'Left'
    $exportBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 24)
    $panel.Children.Add($exportBtn) | Out-Null

    # ---- Import ----
    $panel.Children.Add((New-MaText 'IMPORT (new install)' 13 $text $true ([System.Windows.Thickness]::new(0, 0, 0, 8)))) | Out-Null
    $panel.Children.Add((New-MaText 'Bundle folder (Migration_*):' 12 $dim $false ([System.Windows.Thickness]::new(0, 0, 0, 4)))) | Out-Null
    $impPath = New-MaPathRow $text $inputBg $inputBorder
    $panel.Children.Add($impPath.Row) | Out-Null

    $impPrinters = New-MaCheck 'Printers' $true $text
    $impDrives = New-MaCheck 'Network drives and credential reminders' $true $text
    $impWifi = New-MaCheck 'Wi-Fi, proxy, hosts file, VPN' $true $text
    $impSys = New-MaCheck 'System settings' $true $text
    $impStatic = New-MaCheck 'Also restore static IP settings (may break connectivity on a different subnet)' $false $text
    $impOverwrite = New-MaCheck 'Overwrite existing printers (PrintBrm FORCE)' $false $text
    foreach ($c in $impPrinters, $impDrives, $impWifi, $impSys, $impStatic, $impOverwrite) { $panel.Children.Add($c) | Out-Null }

    $panel.Children.Add((New-MaText 'Passphrase:' 12 $dim $false ([System.Windows.Thickness]::new(0, 8, 0, 4)))) | Out-Null
    $impPass = New-MaPasswordBox $text $inputBg $inputBorder
    $panel.Children.Add($impPass) | Out-Null

    $impRow = New-Object System.Windows.Controls.StackPanel
    $impRow.Orientation = 'Horizontal'
    $impRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    $previewBtn = New-Object System.Windows.Controls.Button
    $previewBtn.Content = 'Preview (no changes)'
    $previewBtn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $impRow.Children.Add($previewBtn) | Out-Null
    $importBtn = New-Object System.Windows.Controls.Button
    $importBtn.Content = 'Import'
    $importBtn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $importBtn.FontWeight = 'Bold'
    $importBtn.Background = $accent
    $importBtn.Foreground = $dark
    $importBtn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $impRow.Children.Add($importBtn) | Out-Null
    $openBtn = New-Object System.Windows.Controls.Button
    $openBtn.Content = 'Open Report Folder'
    $openBtn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $openBtn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $impRow.Children.Add($openBtn) | Out-Null
    $panel.Children.Add($impRow) | Out-Null

    $statusText = New-Object System.Windows.Controls.TextBlock
    $statusText.Text = 'Reports are saved to C:\_INFO\MigrationAssist'
    $statusText.FontSize = 13
    $statusText.Foreground = $text
    $statusText.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $statusText.TextWrapping = 'Wrap'
    $statusText.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0)
    $panel.Children.Add($statusText) | Out-Null

    # Runs Invoke-MigrationExport / Invoke-MigrationImport in an STA runspace.
    $launch = {
        param([string]$Mode, [hashtable]$Params)
        $h = $Global:SyncHash.MigrationAssist
        foreach ($b in $h.Buttons) { $b.IsEnabled = $false }
        $h.StatusText.Text = "$Mode running..."

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('SyncHash', $Global:SyncHash)
        $rs.SessionStateProxy.SetVariable('MaMode', $Mode)
        $rs.SessionStateProxy.SetVariable('MaParams', $Params)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $ps.AddScript({
            $toolkitRoot = $SyncHash.Toolkit.Root
            Get-ChildItem -Path "$toolkitRoot\Core" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
            Get-ChildItem -Path "$toolkitRoot\UI" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
            . (Join-Path $toolkitRoot 'Modules\Migration-Assist.ps1')

            $statusMsg = $null
            try {
                if ($MaMode -eq 'Export') { $res = Invoke-MigrationExport @MaParams }
                else { $res = Invoke-MigrationImport @MaParams }
                $s = $res.Summary
                $label = $MaMode
                if ($MaMode -eq 'Import' -and $res.Preview) { $label = 'Preview' }
                $statusMsg = "{0} done: {1} ok, {2} warnings, {3} failed, {4} skipped, {5} preview.`nReport: {6}" -f $label, $s.Ok, $s.Warnings, $s.Failed, $s.Skipped, $s.Preview, $res.Report
                if ($MaMode -eq 'Export') { $statusMsg += "`nBundle: $($res.Bundle)" }
            } catch {
                Write-Log "Migration $MaMode failed: $($_.Exception.Message)" -Level Error
                $statusMsg = "Failed: $($_.Exception.Message)"
            } finally {
                $MaParams.Passphrase = $null
                $SyncHash.Window.Dispatcher.Invoke([action]{
                    foreach ($b in $SyncHash.MigrationAssist.Buttons) { $b.IsEnabled = $true }
                    $SyncHash.MigrationAssist.StatusText.Text = $statusMsg
                })
            }
        }) | Out-Null
        $ps.BeginInvoke() | Out-Null
    }

    $Global:SyncHash.MigrationAssist = @{
        StatusText = $statusText
        Buttons    = @($exportBtn, $previewBtn, $importBtn)
        Launch     = $launch
    }

    # Browse buttons
    $browse = {
        param($Box)
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($Box.Text -and (Test-Path $Box.Text)) { $dlg.SelectedPath = $Box.Text }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $Box.Text = $dlg.SelectedPath }
    }
    $expBox = $expPath.Box
    $impBox = $impPath.Box
    $expPath.Button.Add_Click({ & $browse $expBox }.GetNewClosure())
    $impPath.Button.Add_Click({ & $browse $impBox }.GetNewClosure())

    $openBtn.Add_Click({
        try { $dir = Get-ToolkitInfoPath -Module 'MigrationAssist' }
        catch { $Global:SyncHash.MigrationAssist.StatusText.Text = $_.Exception.Message; return }
        Start-Process explorer.exe -ArgumentList "`"$dir`""
    }.GetNewClosure())

    $exportBtn.Add_Click({
        $h = $Global:SyncHash.MigrationAssist
        $cats = @()
        if ($expPrinters.IsChecked) { $cats += 'Printers' }
        if ($expDrives.IsChecked) { $cats += 'NetworkDrives' }
        if ($expWifi.IsChecked) { $cats += 'WifiNetwork' }
        if ($expSys.IsChecked) { $cats += 'SystemSettings' }
        if ($cats.Count -eq 0) { $h.StatusText.Text = 'Select at least one category.'; return }
        if (-not $expBox.Text.Trim()) { $h.StatusText.Text = 'Choose where to save the bundle.'; return }
        if ($expPass.Password.Length -lt 8) { $h.StatusText.Text = 'Passphrase must be at least 8 characters.'; return }
        if ($expPass.Password -ne $expPass2.Password) { $h.StatusText.Text = 'Passphrases do not match.'; return }
        $params = @{
            Destination           = $expBox.Text.Trim()
            Categories            = $cats
            Passphrase            = $expPass.Password
            IncludeDriverPackages = [bool]$expDrivers.IsChecked
            IncludeWifiProfiles   = [bool]$expWifiKeys.IsChecked
        }
        & $h.Launch 'Export' $params
    }.GetNewClosure())

    $importHandler = {
        param([bool]$Preview)
        $h = $Global:SyncHash.MigrationAssist
        $cats = @()
        if ($impPrinters.IsChecked) { $cats += 'Printers' }
        if ($impDrives.IsChecked) { $cats += 'NetworkDrives' }
        if ($impWifi.IsChecked) { $cats += 'WifiNetwork' }
        if ($impSys.IsChecked) { $cats += 'SystemSettings' }
        if ($cats.Count -eq 0) { $h.StatusText.Text = 'Select at least one category.'; return }
        if (-not $impBox.Text.Trim() -or -not (Test-Path $impBox.Text.Trim())) { $h.StatusText.Text = 'Choose the bundle folder.'; return }
        $params = @{
            Bundle          = $impBox.Text.Trim()
            Categories      = $cats
            Passphrase      = $impPass.Password
            Preview         = $Preview
            RestoreStaticIp = [bool]$impStatic.IsChecked
            Overwrite       = [bool]$impOverwrite.IsChecked
        }
        $mode = 'Import'
        & $h.Launch $mode $params
    }.GetNewClosure()

    $previewBtn.Add_Click({ & $importHandler $true }.GetNewClosure())
    $importBtn.Add_Click({
        $answer = [System.Windows.MessageBox]::Show(
            'Import will create printers, drives, Wi-Fi profiles and settings on this PC. Existing items are skipped. Continue?',
            'Migration Assist', 'YesNo', 'Question')
        if ($answer -eq 'Yes') { & $importHandler $false }
    }.GetNewClosure())

    $scroll.Content = $panel
    return $scroll
}
