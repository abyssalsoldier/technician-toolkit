# Invoke-EndpointSetup.ps1
# Endpoint Toolkit v2 — WPF GUI orchestrator (core; client branding/modules come from client\, see ClientOverlay.ps1)
# Run as Administrator

param(
    [string]$UsbDrive,
    [string]$UsbSerial,
    [switch]$Localized
)

# --- Admin elevation ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script requires Administrator privileges. Relaunching as Administrator..."

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

    if (-not $scriptPath) {
        Write-Host "Error: Could not determine script path. Ensure the file is saved before running." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit
    }

    $relaunchArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    if ($Localized) { $relaunchArgs += " -Localized" }
    if ($UsbDrive)  { $relaunchArgs += " -UsbDrive `"$UsbDrive`"" }
    if ($UsbSerial) { $relaunchArgs += " -UsbSerial `"$UsbSerial`"" }
    Start-Process powershell -WindowStyle Hidden -ArgumentList $relaunchArgs -Verb RunAs
    exit
}

# --- Initialize toolkit context ---
$script:Toolkit = @{
    Version       = (Get-Content "$PSScriptRoot\version.txt" -ErrorAction SilentlyContinue).Trim()
    Root          = $PSScriptRoot                          # dependencies/

    Parent        = Split-Path $PSScriptRoot -Parent       # repo root (where Launch.bat lives)
    IsUsb         = $false
    UsbDrive      = $null
    UsbSerial     = $null
    Config        = $null
    Authenticated = $false
    Session       = $null
}

# Hide the console window
$win32Signature = @'
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
'@
$win32Api = Add-Type -MemberDefinition $win32Signature -Name 'Win32Console' -Namespace 'Win32' -PassThru
$win32Api::ShowWindow($win32Api::GetConsoleWindow(), 0) | Out-Null


if (-not $script:Toolkit.Version) { $script:Toolkit.Version = "0.0.0" }

$script:ToolkitKey = $null

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Create working directory
$workDir = "$env:TEMP\InstallApps"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# --- Load Core modules ---
$corePath = "$PSScriptRoot\Core"
if (Test-Path $corePath) {
    Get-ChildItem -Path $corePath -Filter "*.ps1" -File | ForEach-Object { . $_.FullName }
} else {
    Write-Host "FATAL: Core directory not found at '$corePath'." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# --- Client overlay: branding, effective version, update feed (core defaults when client\ is absent) ---
Initialize-ToolkitOverlay
$Host.UI.RawUI.WindowTitle = "$(Get-ToolkitProductName) v$($script:Toolkit.Version)"

# --- Load UI modules ---
$uiPath = "$PSScriptRoot\UI"
if (Test-Path $uiPath) {
    Get-ChildItem -Path $uiPath -Filter "*.ps1" -File | ForEach-Object { . $_.FullName }
} else {
    Write-Host "FATAL: UI directory not found at '$uiPath'." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# --- USB detection, self-update, and local copy ---
# Updates come from the GitHub releases of abyssalsoldier/Endpoint-toolkit (published by .github/workflows/release.yml).
# When launched from a USB, the toolkit is copied to a local temp folder and this running instance is
# re-pointed at it, so the drive can be unplugged at any point after startup.
# The feed comes from client\branding.json UpdateBaseUrl in client builds (empty = no self-update).
$UpdateBaseUrl = Get-ToolkitBrandingValue 'UpdateBaseUrl'
$localCopyRoot = $null
if ($Localized -and $UsbDrive) {
    # Legacy relaunch path (kept for compatibility)
    $script:Toolkit.IsUsb = $true
    $script:Toolkit.UsbDrive = $UsbDrive
    $script:Toolkit.UsbSerial = $UsbSerial
    $localCopyRoot = $script:Toolkit.Parent
} else {
    Test-UsbExecution
    if ($script:Toolkit.IsUsb) {
        if ($UpdateBaseUrl) { Update-UsbToolkit -UpdateBaseUrl $UpdateBaseUrl }

        $usbSerial = Get-DriveSerial -DriveLetter $script:Toolkit.UsbDrive
        # Expand 8.3 short names (e.g. JESSER~1); module discovery compares against long file paths
        $longTemp  = (Get-Item -LiteralPath $env:TEMP).FullName
        $localRoot = (New-Item -ItemType Directory -Path (Join-Path $longTemp "EndpointToolkit_$([guid]::NewGuid().ToString('N'))") -Force).FullName

        $copyError = $null
        try {
            $copyError = Copy-ToolkitToLocal -Source $script:Toolkit.Parent -Destination $localRoot
        } catch {
            $copyError = $_.Exception.Message
        }

        $localScript = "$localRoot\dependencies\Invoke-EndpointSetup.ps1"
        if (-not $copyError -and (Test-Path $localScript)) {
            # Switch this running instance to the local copy; no relaunch needed.
            # Core/UI are already loaded in memory, and everything loaded later
            # (modules, runspaces) resolves through Toolkit.Root / Toolkit.Parent.
            $script:Toolkit.UsbSerial = $usbSerial
            $script:Toolkit.Root      = "$localRoot\dependencies"
            $script:Toolkit.Parent    = $localRoot
            $localCopyRoot            = $localRoot
            Set-Location $env:TEMP
        } else {
            Add-Type -AssemblyName PresentationFramework
            [System.Windows.MessageBox]::Show(
                "Could not copy the toolkit locally ($copyError).`n`nThe toolkit will run from the USB. Do NOT unplug it while the toolkit is open.",
                'Local copy failed', 'OK', 'Warning') | Out-Null
            Remove-Item $localRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Launch GUI ---
Start-ToolkitGUI

# --- Cleanup: wipe sensitive data from memory and disk ---
Write-Host "Cleaning up sensitive data..." -ForegroundColor Yellow

$script:Toolkit.Config = $null
$script:ToolkitKey = $null
$script:Toolkit.Session = $null
if ($Global:SyncHash) {
    $Global:SyncHash.Toolkit.Config = $null
    $Global:SyncHash.ToolkitKey = $null
    $Global:SyncHash = $null
}

$tempPaths = @(
    "$env:TEMP\InstallApps",
    "$env:TEMP\endpoint-toolkit-update",
    "$env:TEMP\endpoint-toolkit-update.zip"
)
foreach ($p in $tempPaths) {
    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}

# Remove the local copy made from the USB at startup
if ($localCopyRoot -and (Split-Path $localCopyRoot -Leaf).StartsWith('EndpointToolkit_', [System.StringComparison]::OrdinalIgnoreCase)) {
    Set-Location $env:TEMP
    Remove-Item $localCopyRoot -Recurse -Force -ErrorAction SilentlyContinue
}



[System.GC]::Collect()
Write-Host "Done. Session cleaned." -ForegroundColor Green
