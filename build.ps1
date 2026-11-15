# build.ps1 — Local build and test script for Technician Toolkit
# Mirrors the same exclusions as .github/workflows/release.yml
#
# Usage:
#   .\build.ps1              # Creates a timestamped zip build in _builds\
#   .\build.ps1 -Extract     # Also extracts the zip for inspection
#   .\build.ps1 -Dev         # Copies files directly (no zip) — fastest for testing
#   .\build.ps1 -Test        # Same as -Dev but also launches the toolkit
#   .\build.ps1 -SFX         # Zip + self-extracting EndpointToolkit.exe
#   .\build.ps1 -Folder      # Also a ready-to-run folder (_builds\v...\EndpointToolkit\Launch.bat); combines with -SFX
#   -OutputPath D:\Builds    # Write the builds there instead of _builds\ (must be outside the toolkit folder)
#
# Core integrity: every build checks core files against dependencies\core-manifest.json.
# With a client\ folder the build is REFUSED when core was changed. Core maintainers:
#   .\build.ps1 -UpdateCoreManifest   # regenerate the manifest after changing core (then commit it)
#   -AllowModifiedCore                # build anyway (core maintainers only, never in client repos)

param(
    [switch]$Extract,
    [switch]$Dev,
    [switch]$Test,
    [switch]$SFX,
    [switch]$Folder,
    [string]$OutputPath,
    [switch]$UpdateCoreManifest,
    [switch]$AllowModifiedCore
)

$ErrorActionPreference = "Stop"

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

$repoRoot = $PSScriptRoot
$buildsRoot = Join-Path $repoRoot "_builds"

# Client overlay helpers (branding, effective version, repo-only excludes) + core integrity
. (Join-Path $repoRoot "dependencies\Core\ClientOverlay.ps1")
. (Join-Path $repoRoot "dependencies\Agent\CoreIntegrity.ps1")

if ($UpdateCoreManifest) {
    if (Test-Path (Join-Path $repoRoot "client")) {
        Write-Host "Refusing to update the core manifest in a client repo (client\ exists). Only core maintainers regenerate it." -ForegroundColor Red
        exit 1
    }
    $count = New-ToolkitCoreManifest -Root $repoRoot
    Write-Host "core-manifest.json updated ($count core files). Commit it with your core changes." -ForegroundColor Green
    exit 0
}
if (-not (Assert-ToolkitCoreIntegrity -Root $repoRoot -AllowModifiedCore:$AllowModifiedCore)) { exit 1 }

if ($OutputPath) {
    $why = Test-ToolkitBuildOutputPath -Root $repoRoot -Path $OutputPath
    if ($why) { Write-Host "ERROR: $why" -ForegroundColor Red; exit 1 }
    $buildsRoot = [System.IO.Path]::GetFullPath($OutputPath).TrimEnd('\')
}

$overlayWarnings = [System.Collections.ArrayList]::new()
$branding = Get-ToolkitBranding -Parent $repoRoot -Warnings $overlayWarnings
foreach ($w in $overlayWarnings) { Write-Host "WARNING: $w" -ForegroundColor Yellow }

# Effective version: client\version.txt when present, else dependencies\version.txt
$versionInfo = Get-ToolkitVersionInfo -Root (Join-Path $repoRoot "dependencies") -Parent $repoRoot
$version = $versionInfo.Effective
$productName = if ($branding.IsClient) { $branding.ProductName } else { "Technician Toolkit" }
# Exe name stays EndpointToolkit.exe (ConnectWise Toolbox entries depend on it) unless the client sets ExeName
$exeBaseName = if ($branding.ExeName) { $branding.ExeName } else { "EndpointToolkit" }

# Create timestamped build folder: _builds\v1.0.0_2026-03-26_1430
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$buildName = "v${version}_${timestamp}"
$buildDir = Join-Path $buildsRoot $buildName

Write-Host "Building $productName v$version" -ForegroundColor Cyan
if ($versionInfo.Client) { Write-Host "  Core: v$($versionInfo.Core)  Client: v$($versionInfo.Client)" -ForegroundColor White }
Write-Host "  Output: $buildDir" -ForegroundColor White
Write-Host ""

New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

# Common robocopy exclusions (mirrors release.yml)
$repoOnly = Get-ToolkitPayloadExcludes -Root $repoRoot   # tools\, client.example\, agent/client docs
$robocopyExcludeDirs = @(".git", ".github", ".claude", ".vscode", "_builds") + @($repoOnly.Dirs | ForEach-Object { ConvertTo-RobocopyPathArg $_ })
$robocopyExcludeFiles = @(".gitignore", ".gitattributes", "README.md", "build.ps1") + @($repoOnly.Files | ForEach-Object { ConvertTo-RobocopyPathArg $_ })

if ($Dev -or $Test) {
    # --- Dev mode: copy files directly, no zip ---
    $outputPath = $buildDir

    $robocopyArgs = @(
        (ConvertTo-RobocopyPathArg $repoRoot),
        (ConvertTo-RobocopyPathArg $outputPath),
        "/MIR",
        "/XD") + $robocopyExcludeDirs + @("/XF") + $robocopyExcludeFiles + @(
        "/NFL", "/NDL", "/NJH", "/NJS",
        "/R:2", "/W:1"
    )
    $proc = Start-Process robocopy -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ge 8) {
        Write-Host "Error during copy (robocopy exit code $($proc.ExitCode))." -ForegroundColor Red
        exit 1
    }

    # Remove *.key files
    Get-ChildItem -Path $outputPath -Filter "*.key" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force

    Write-Host "Dev build complete: $outputPath" -ForegroundColor Green
    Write-Host ""

    if ($Test) {
        Write-Host "Launching toolkit..." -ForegroundColor Yellow
        $launchBat = Join-Path $outputPath "Launch.bat"
        if (Test-Path $launchBat) {
            Start-Process cmd.exe -ArgumentList "/c `"$launchBat`"" -Verb RunAs -WindowStyle Hidden
        } else {
            $setupScript = Join-Path $outputPath "dependencies\Invoke-EndpointSetup.ps1"
            if (Test-Path $setupScript) {
                Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$setupScript`"" -Verb RunAs -WindowStyle Hidden
            } else {
                Write-Host "Could not find launch entry point." -ForegroundColor Red
            }
        }
    }
} else {
    # --- Release mode: create zip + checksum ---
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zipPath = Join-Path $buildDir "endpoint-build-toolkit.zip"
    $checksumPath = Join-Path $buildDir "latest.sha256"

    $tempStaging = Join-Path $env:TEMP "toolkit-build-staging"
    if (Test-Path $tempStaging) { Remove-Item $tempStaging -Recurse -Force }
    New-Item -ItemType Directory -Path $tempStaging -Force | Out-Null

    $robocopyArgs = @(
        (ConvertTo-RobocopyPathArg $repoRoot),
        (ConvertTo-RobocopyPathArg $tempStaging),
        "/MIR",
        "/XD") + $robocopyExcludeDirs + @("/XF") + $robocopyExcludeFiles + @(
        "/NFL", "/NDL", "/NJH", "/NJS",
        "/R:2", "/W:1"
    )
    $proc = Start-Process robocopy -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ge 8) {
        Write-Host "Error during staging copy (robocopy exit code $($proc.ExitCode))." -ForegroundColor Red
        exit 1
    }

    # Remove *.key files from staging
    Get-ChildItem -Path $tempStaging -Filter "*.key" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force

    # Locked client modules (RequiresAuth, or LockedModules in branding.json) are left out: this zip,
    # its exe and folder have no password, so their code must not ship in them. Use the locked exe.
    . (Join-Path $repoRoot "dependencies\Agent\LockedPayload.ps1")   # Get-ToolkitLockedModuleInfo
    $omitted = @(Get-ToolkitLockedModuleInfo -Root $tempStaging)
    foreach ($m in $omitted) { Remove-Item -LiteralPath $m.File -Force }
    if ($omitted.Count) {
        Write-Host "  Locked modules left out (no password in this build): $(($omitted | ForEach-Object { $_.Label }) -join ', ')" -ForegroundColor Yellow
    }

    # Ready-to-run folder: exactly the zip's contents, unzipped (run Launch.bat inside it)
    if ($Folder) {
        $folderPath = Join-Path $buildDir $exeBaseName
        $folderArgs = @((ConvertTo-RobocopyPathArg $tempStaging), (ConvertTo-RobocopyPathArg $folderPath), "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/R:2", "/W:1")
        $proc = Start-Process robocopy -ArgumentList $folderArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ge 8) {
            Write-Host "Error creating the folder build (robocopy exit code $($proc.ExitCode))." -ForegroundColor Red
            exit 1
        }
    }

    # Create zip
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempStaging, $zipPath)
    Remove-Item $tempStaging -Recurse -Force

    # Generate SHA-256 checksum
    $hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
    Set-Content -Path $checksumPath -Value $hash -NoNewline

    $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)

    Write-Host "Build complete:" -ForegroundColor Green
    Write-Host "  Zip : $zipPath ($zipSize MB)" -ForegroundColor White
    Write-Host "  SHA : $hash" -ForegroundColor White
    if ($Folder) { Write-Host "  Run : $(Join-Path $folderPath 'Launch.bat')" -ForegroundColor White }
    Write-Host ""

    if ($SFX) {
        Write-Host "Creating Self-Extracting EXE wrapper (SFX) using IExpress..." -ForegroundColor Cyan

        # The finished exe goes to the builds root (default _builds\, or -OutputPath)
        $targetExe = Join-Path $buildsRoot "$exeBaseName.exe"
        if (Test-Path $targetExe) { Remove-Item $targetExe -Force -ErrorAction SilentlyContinue }

        # IExpress fails on any path containing a space, so it compiles in a space-free work folder
        # and the exe is moved to the chosen output folder afterwards.
        $iexBase = $env:TEMP
        if ($iexBase -match '\s') {
            try { $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($iexBase).ShortPath; if ($short -notmatch '\s') { $iexBase = $short } } catch { }
        }
        if ($iexBase -match '\s') { $iexBase = $env:ProgramData }
        $iexDir = Join-Path $iexBase "toolkit-sfx-$([guid]::NewGuid().ToString('N'))"
        if ($iexDir -match '\s') { Write-Host "No folder without spaces was found for IExpress (TEMP: $env:TEMP)." -ForegroundColor Red; exit 1 }
        New-Item -ItemType Directory -Path $iexDir -Force | Out-Null
        Copy-Item -LiteralPath $zipPath -Destination (Join-Path $iexDir 'endpoint-build-toolkit.zip')
        $iexExe = Join-Path $iexDir "$exeBaseName.exe"

        $bootstrapPath = Join-Path $iexDir "bootstrap.ps1"
        $sedPath = Join-Path $iexDir "sfx.sed"

        # 1. Write the bootstrap script
        $bootstrapScript = @'
# bootstrap.ps1 for Technician Toolkit SFX
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework

$tempDir = Join-Path $env:TEMP "EndpointToolkit_SC"
# Extracted under a random name first, then renamed to EndpointToolkit_SC (see below)
$staging = Join-Path $env:TEMP ("EndpointToolkit_SC_" + [guid]::NewGuid().ToString('N'))
# Fail closed: under SYSTEM, TEMP is the shared C:\Windows\Temp where any user can pre-create this
# folder with planted files. Never extract into a folder that could not be removed, secured and verified.
# The private DACL is part of the folder's creation, so no other user ever gets a handle to it.
# [IO.Directory]::Delete(recursive) does not follow junctions/symlinks (Remove-Item -Recurse in
# Windows PowerShell 5.1 can, which would delete files elsewhere as SYSTEM).
try {
    if ([System.IO.Directory]::Exists($tempDir)) { [System.IO.Directory]::Delete($tempDir, $true) }
    if ([System.IO.Directory]::Exists($tempDir)) { throw 'the previous copy could not be removed' }
    if ([System.IO.Directory]::Exists($staging)) { throw 'the staging folder already exists' }
    $me     = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $admins = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($me)
    foreach ($sid in $me, $system, $admins) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    $null = [System.IO.Directory]::CreateDirectory($staging, $acl)
    if ([System.IO.File]::GetAttributes($staging) -band [System.IO.FileAttributes]::ReparsePoint) { throw 'the folder is a link' }
    if (@([System.IO.Directory]::GetFileSystemEntries($staging)).Count -gt 0) { throw 'the folder is not empty' }
    $owner = [System.IO.Directory]::GetAccessControl($staging).GetOwner([System.Security.Principal.SecurityIdentifier])
    if (-not ($owner.Equals($me) -or $owner.Equals($system) -or $owner.Equals($admins))) { throw 'the folder has an untrusted owner' }
} catch {
    try { if ([System.IO.Directory]::Exists($staging)) { [System.IO.Directory]::Delete($staging, $true) } } catch { }
    [System.Windows.MessageBox]::Show("Refusing to start: $tempDir is not safe ($($_.Exception.Message)). Delete it as an administrator and run again.", "Error", "OK", "Error") | Out-Null
    exit 1
}

$zipPath = Join-Path $PSScriptRoot "endpoint-build-toolkit.zip"
if (-not (Test-Path $zipPath)) {
    try { [System.IO.Directory]::Delete($staging, $true) } catch { }
    [System.Windows.MessageBox]::Show("Fatal: Toolkit archive not found.", "Error", "OK", "Error") | Out-Null
    exit 1
}

try {
    # Extract zip archive, then atomically rename to the runtime name (fails if someone re-created
    # EndpointToolkit_SC in the meantime: fail closed)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $staging)
    [System.IO.Directory]::Move($staging, $tempDir)

    # Launch Invoke-EndpointSetup.ps1 as Admin
    $setupScript = Join-Path $tempDir "dependencies\Invoke-EndpointSetup.ps1"
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$setupScript`"" -Verb RunAs -Wait -WindowStyle Hidden
} catch {
    [System.Windows.MessageBox]::Show("Failed to launch toolkit: $($_.Exception.Message)", "Launch Error", "OK", "Error") | Out-Null
} finally {
    # Cleanup temp folders after exit (link-safe delete, see above)
    foreach ($d in $staging, $tempDir) {
        try { if ([System.IO.Directory]::Exists($d)) { [System.IO.Directory]::Delete($d, $true) } } catch { }
    }
}
'@
        Set-Content -Path $bootstrapPath -Value $bootstrapScript -Encoding ascii -Force

        # 2. Write the IExpress SED configuration file
        $srcDir = $iexDir
        if (-not $srcDir.EndsWith("\")) { $srcDir += "\" }
        
        $sedContent = @"
[Version]
Class=IEXPRESS
SEDVersion=3

[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=1
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=I
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles

[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$iexExe
FriendlyName=$productName
AppLaunched=powershell.exe -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
FILE0=endpoint-build-toolkit.zip
FILE1=bootstrap.ps1

[SourceFiles]
SourceFiles0=$srcDir

[SourceFiles0]
%FILE0%=
%FILE1%=
"@
        Set-Content -Path $sedPath -Value $sedContent -Encoding ascii -Force

        # Ensure files are not locked by the OS or Antivirus before compiling
        $filesToCheck = @((Join-Path $iexDir 'endpoint-build-toolkit.zip'), $bootstrapPath, $sedPath)
        foreach ($file in $filesToCheck) {
            $unlocked = $false
            for ($i = 0; $i -lt 10; $i++) {
                try {
                    $stream = [System.IO.File]::Open($file, 'Open', 'Read', 'None')
                    $stream.Close()
                    $unlocked = $true
                    break
                } catch {
                    Write-Host "Waiting for file lock release on: $(Split-Path $file -Leaf)..." -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 500
                }
            }
            if (-not $unlocked) {
                Write-Host "Warning: $(Split-Path $file -Leaf) may still be locked." -ForegroundColor Red
            }
        }

        # 3. Execute IExpress via Start-Process to wait for complete compilation
        Write-Host "Compiling SFX..." -ForegroundColor Yellow
        $proc = Start-Process iexpress -ArgumentList "/N", "/Q", $sedPath -Wait -NoNewWindow -PassThru
        $exitCode = $proc.ExitCode

        if ($exitCode -eq 0 -and (Test-Path $iexExe)) {
            Move-Item -LiteralPath $iexExe -Destination $targetExe -Force
            Remove-Item -LiteralPath $iexDir -Recurse -Force -ErrorAction SilentlyContinue

            $exeSize = [math]::Round((Get-Item $targetExe).Length / 1MB, 2)
            Write-Host "SFX build complete: $targetExe ($exeSize MB)" -ForegroundColor Green
            Write-Host ""
        } else {
            Write-Host "SFX compilation failed (iexpress exit code $exitCode)." -ForegroundColor Red
            Write-Host "Staged files left at $iexDir for debugging (sfx.sed, bootstrap.ps1)." -ForegroundColor Yellow
            Write-Host ""
            exit 1
        }
    }

    # Extract if requested
    if ($Extract) {
        $extractPath = Join-Path $buildDir "extracted"
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        Write-Host "Extracted to: $extractPath" -ForegroundColor Green
    }
}
