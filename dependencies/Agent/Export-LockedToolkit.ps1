# Export-LockedToolkit.ps1
# Compiles the current toolkit into a standalone, password-protected Self-Extracting Executable (SFX).
# The resulting .exe can be distributed safely, and cannot be accessed without the password.
#
# Interactive:     .\Export-LockedToolkit.ps1                     (prompts for password and output folder)
# From the wizard: .\Export-LockedToolkit.ps1 -Password $secure -OutputPath C:\out
# Client builds are refused when core files differ from core-manifest.json (see CoreIntegrity.ps1).

param(
    [SecureString]$Password,
    [string]$OutputPath,
    [switch]$AllowModifiedCore
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$toolkitRoot = (Resolve-Path (Join-Path $scriptDir "..\..")).Path

# Load Crypto module (+ ConvertTo-RobocopyPathArg from UsbDetection)
. (Join-Path $toolkitRoot "dependencies\Core\Crypto.ps1")
. (Join-Path $toolkitRoot "dependencies\Core\UsbDetection.ps1")
. (Join-Path $toolkitRoot "dependencies\Core\ClientOverlay.ps1")
. (Join-Path $toolkitRoot "dependencies\Core\SafeFileSystem.ps1")
. (Join-Path $toolkitRoot "dependencies\Agent\CoreIntegrity.ps1")
. (Join-Path $toolkitRoot "dependencies\Agent\LockedPayload.ps1")

if (-not (Assert-ToolkitCoreIntegrity -Root $toolkitRoot -AllowModifiedCore:$AllowModifiedCore)) { exit 1 }

# Exe name stays EndpointToolkit_Locked.exe (ConnectWise Toolbox entries depend on it) unless client\branding.json sets ExeName
$branding = Get-ToolkitBranding -Parent $toolkitRoot
$exeBaseName = if ($branding.ExeName) { $branding.ExeName } else { "EndpointToolkit" }
$repoOnly = Get-ToolkitPayloadExcludes -Root $toolkitRoot   # tools\, client.example\, agent/client docs

Write-Host "=== Export Locked Toolkit ===" -ForegroundColor Cyan
Write-Host "This will package the current toolkit folder into a standalone .exe file."
Write-Host ""

$password = if ($Password) { $Password } else { Read-Host "Enter the password to lock this toolkit" -AsSecureString }
if ($password.Length -lt 8) {
    Write-Host "ERROR: Password must be at least 8 characters." -ForegroundColor Red
    exit 1
}
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$outPath = if ($OutputPath) { $OutputPath } else { Read-Host "Enter output path (e.g., C:\Users\Public\Desktop)" }
$why = Test-ToolkitBuildOutputPath -Root $toolkitRoot -Path $outPath
if ($why) { Write-Host "ERROR: $why" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $outPath)) {
    try { New-Item -ItemType Directory -Path $outPath -Force | Out-Null }
    catch { Write-Host "Output folder can't be created: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}

$targetExe = Join-Path $outPath "${exeBaseName}_Locked.exe"

Write-Host "`nStaging toolkit..." -ForegroundColor Yellow
$tempStaging = Join-Path $env:TEMP "ToolkitExport_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $tempStaging -Force | Out-Null

$robocopyArgs = @(
    (ConvertTo-RobocopyPathArg $toolkitRoot),
    (ConvertTo-RobocopyPathArg $tempStaging),
    '/MIR',
    '/XD', '.git', '.github', '.claude', '.vscode', 'Installers', '_builds') +
    @($repoOnly.Dirs | ForEach-Object { ConvertTo-RobocopyPathArg $_ }) + @(
    '/XF', '.gitignore', 'Export-LockedToolkit.ps1', '.toolkit-key', 'build.ps1') +
    @($repoOnly.Files | ForEach-Object { ConvertTo-RobocopyPathArg $_ }) + @(
    '/NFL', '/NDL', '/NJH', '/NJS',
    '/R:2', '/W:1'
)
$proc = Start-Process robocopy -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ge 8) { throw "Robocopy failed." }

Write-Host "Encrypting locked modules and secrets..." -ForegroundColor Yellow
# Random main key (OS CSPRNG). It encrypts the vault (locked client modules + wizard secrets) and is
# itself only stored wrapped with the password (.sfx-key).
$mainToolkitKey = New-ToolkitMainKey
$secrets = [ordered]@{}
$clientDir = Join-Path $toolkitRoot 'client'
if (Test-Path $clientDir) {
    try { $secrets = Read-ToolkitSecretStore -ClientRoot $clientDir }
    catch {
        Remove-Item $tempStaging -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "ERROR: client\secrets.dat can't be read by this Windows user (it was saved by another user or PC)." -ForegroundColor Red
        Write-Host "Open the Client Setup wizard, Secrets page, and enter the values again." -ForegroundColor Red
        exit 1
    }
}
$payload = New-ToolkitLockedPayload -Root $tempStaging -MainKey $mainToolkitKey -Secrets $secrets
$secrets = $null
Write-Host "  Locked modules: $(if ($payload.LockedModules.Count) { $payload.LockedModules -join ', ' } else { 'none' })" -ForegroundColor White
Write-Host "  Secrets       : $($payload.SecretCount)" -ForegroundColor White

Write-Host "Generating AES-256 .sfx-key..." -ForegroundColor Yellow
$encryptedPassword = Protect-SfxPassword -MainToolkitKey $mainToolkitKey -SfxPassword $plainPassword
Set-Content -Path "$tempStaging\.sfx-key" -Value $encryptedPassword -NoNewline -Force
(Get-Item "$tempStaging\.sfx-key" -Force).Attributes = 'Hidden'

Write-Host "Compressing payload..." -ForegroundColor Yellow
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath = Join-Path $env:TEMP "toolkit-payload-$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
[System.IO.Compression.ZipFile]::CreateFromDirectory($tempStaging, $zipPath)

Write-Host "Compiling SFX Executable..." -ForegroundColor Yellow
# Version info shown in file properties and EDR consoles, from whoever builds this exe:
# core build -> core defaults (Technician Toolkit / JRankinTech), client build -> their branding.json
# (CompanyName, or their ProductName when it is empty). Values are admin input: escaped for C#.
function ConvertTo-StubCSharpString {
    param([string]$Text)
    $t = ($Text -replace '[\x00-\x1F]', '').Replace('\', '\').Replace('"', '\"')
    return '"' + $t + '"'
}
$stubProduct = if ($branding.ProductName) { $branding.ProductName } else { (Get-ToolkitCoreDefaults).ProductName }
$stubCompany = if ($branding.CompanyName) { $branding.CompanyName } else { $stubProduct }
$stubVersionText = (Get-ToolkitVersionInfo -Root (Join-Path $toolkitRoot 'dependencies') -Parent $toolkitRoot).Effective
$stubVersionParts = @(([version]$stubVersionText).ToString().Split('.') | ForEach-Object { [int]$_ })
while ($stubVersionParts.Count -lt 4) { $stubVersionParts += 0 }
$stubVersion = ($stubVersionParts[0..3] | ForEach-Object { [Math]::Min([Math]::Max($_, 0), 65534) }) -join '.'
$csProduct = ConvertTo-StubCSharpString $stubProduct
$csCompany = ConvertTo-StubCSharpString $stubCompany
$csDescription = ConvertTo-StubCSharpString "$stubProduct (locked)"
$csVersion = ConvertTo-StubCSharpString $stubVersion
$csharpCode = @"
using System;
using System.IO;
using System.IO.Compression;
using System.Diagnostics;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle($csProduct)]
[assembly: AssemblyProduct($csProduct)]
[assembly: AssemblyDescription($csDescription)]
[assembly: AssemblyCompany($csCompany)]
[assembly: AssemblyVersion($csVersion)]
[assembly: AssemblyFileVersion($csVersion)]
[assembly: AssemblyInformationalVersion($csVersion)]

namespace EndpointToolkit
{
    class Program
    {
        // A windowed (not console) app: no console window. Errors are shown in a message box when someone
        // is at the screen; otherwise (e.g. ConnectWise backstage as SYSTEM) only the exit code reports them.
        static int Fail(string message)
        {
            if (Environment.UserInteractive) {
                try { MessageBox.Show(message, $csProduct, MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
            return 1;
        }

        static int Main(string[] args)
        {
            string exePath = Assembly.GetExecutingAssembly().Location;
            string tempDir = Path.Combine(Path.GetTempPath(), "EndpointToolkit_SC");
            // Extracted under a random name first, then renamed to EndpointToolkit_SC (see below)
            string staging = Path.Combine(Path.GetTempPath(), "EndpointToolkit_SC_" + Guid.NewGuid().ToString("N"));

            // Fail closed: under ConnectWise/SYSTEM, TEMP is the shared C:\Windows\Temp where any user can
            // pre-create this folder (with planted .ps1 files and an ACL that blocks deletion). The kit is
            // never extracted into a folder that could not be removed, secured and verified.
            // The private DACL is part of the folder's creation, so no other user ever gets a handle to it
            // (creating first and securing afterwards leaves a window in which a handle can be opened and
            // kept). Directory.Delete(recursive) does not follow junctions/symlinks (.NET Framework).
            try {
                if (Directory.Exists(tempDir)) { Directory.Delete(tempDir, true); }
                if (Directory.Exists(tempDir)) { throw new IOException("the previous copy could not be removed"); }
                // Only this user, SYSTEM and Administrators may open the extracted kit
                var me = System.Security.Principal.WindowsIdentity.GetCurrent().User;
                var system = new System.Security.Principal.SecurityIdentifier(System.Security.Principal.WellKnownSidType.LocalSystemSid, null);
                var admins = new System.Security.Principal.SecurityIdentifier(System.Security.Principal.WellKnownSidType.BuiltinAdministratorsSid, null);
                var sec = new System.Security.AccessControl.DirectorySecurity();
                sec.SetAccessRuleProtection(true, false);
                sec.SetOwner(me);
                var inherit = System.Security.AccessControl.InheritanceFlags.ContainerInherit | System.Security.AccessControl.InheritanceFlags.ObjectInherit;
                var full = System.Security.AccessControl.FileSystemRights.FullControl;
                var allow = System.Security.AccessControl.AccessControlType.Allow;
                var none = System.Security.AccessControl.PropagationFlags.None;
                sec.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(me, full, inherit, none, allow));
                sec.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(system, full, inherit, none, allow));
                sec.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(admins, full, inherit, none, allow));
                if (Directory.Exists(staging)) { throw new IOException("the staging folder already exists"); }
                Directory.CreateDirectory(staging, sec);
                // Verify: a real folder (not a link), empty, owned by a trusted principal
                if ((File.GetAttributes(staging) & FileAttributes.ReparsePoint) != 0) { throw new IOException("the folder is a link"); }
                if (Directory.GetFileSystemEntries(staging).Length > 0) { throw new IOException("the folder is not empty"); }
                var owner = Directory.GetAccessControl(staging).GetOwner(typeof(System.Security.Principal.SecurityIdentifier));
                if (!(owner.Equals(me) || owner.Equals(system) || owner.Equals(admins))) { throw new IOException("the folder has an untrusted owner"); }
            } catch (Exception ex) {
                try { if (Directory.Exists(staging)) { Directory.Delete(staging, true); } } catch { }
                return Fail("Refusing to start: " + tempDir + " is not safe (" + ex.Message + ").\n\nDelete it as an administrator and run again.");
            }

            try {
                // Layout: [stub exe][payload zip][8-byte zip offset][8-byte "TKSFX1" marker].
                // .NET's ZipArchive can't read a zip that does not start at byte 0 (its offsets are
                // relative to the zip), so the zip is read from its recorded offset.
                byte[] all = File.ReadAllBytes(exePath);
                int zipStart = 0, zipLength = all.Length;
                if (all.Length > 16 && System.Text.Encoding.ASCII.GetString(all, all.Length - 8, 6) == "TKSFX1") {
                    zipStart = (int)BitConverter.ToInt64(all, all.Length - 16);
                    zipLength = all.Length - 16 - zipStart;
                }
                using (MemoryStream ms = new MemoryStream(all, zipStart, zipLength, false)) {
                    using (ZipArchive archive = new ZipArchive(ms, ZipArchiveMode.Read)) {
                        archive.ExtractToDirectory(staging);
                    }
                }
                all = null;
                // Atomic rename to the runtime name (ConnectWise entries and the cleanup expect EndpointToolkit_SC).
                // Fails if someone re-created EndpointToolkit_SC in the meantime: fail closed.
                Directory.Move(staging, tempDir);
            } catch (Exception ex) {
                try { if (Directory.Exists(staging)) { Directory.Delete(staging, true); } } catch { }
                return Fail("Extraction failed: " + ex.Message);
            }

            // PowerShell starts with a hidden window, so no console shows behind the toolkit's own window
            string setupScript = Path.Combine(tempDir, @"dependencies\Invoke-EndpointSetup.ps1");
            ProcessStartInfo psi = new ProcessStartInfo {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + setupScript + "\"",
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                Verb = "RunAs"
            };
            try {
                Process.Start(psi);
            } catch (Exception ex) {
                return Fail("Launch failed: " + ex.Message);
            }
            return 0;
        }
    }
}
"@

# Compiled under its final name (shown as the original file name in file properties), in a private folder
$stubDir = New-ToolkitPrivateDirectory -Path (Join-Path $env:TEMP "ToolkitStub_$([guid]::NewGuid().ToString('N'))")
$stubPath = Join-Path $stubDir "${exeBaseName}_Locked.exe"
Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies "System.IO.Compression", "System.IO.Compression.FileSystem", "System.Windows.Forms" -OutputAssembly $stubPath -OutputType WindowsApplication

Write-Host "Bundling..." -ForegroundColor Yellow
if (Test-Path $targetExe) { Remove-Item $targetExe -Force }
# [stub][zip][int64 zip offset][8-byte marker] - the stub reads the zip from its offset (see Main)
$stubBytes = [System.IO.File]::ReadAllBytes($stubPath)
$out = [System.IO.File]::Create($targetExe)
try {
    $out.Write($stubBytes, 0, $stubBytes.Length)
    $zipStream = [System.IO.File]::OpenRead($zipPath)
    try { $zipStream.CopyTo($out) } finally { $zipStream.Dispose() }
    $offset = [BitConverter]::GetBytes([long]$stubBytes.Length)
    $out.Write($offset, 0, 8)
    $marker = [System.Text.Encoding]::ASCII.GetBytes("TKSFX1`0`0")
    $out.Write($marker, 0, 8)
} finally { $out.Dispose() }

# Cleanup
Remove-Item $tempStaging -Recurse -Force
Remove-Item $zipPath -Force
Remove-ToolkitTree -LiteralPath $stubDir

Write-Host "`nSUCCESS! Locked toolkit exported to: $targetExe" -ForegroundColor Green
Write-Host "This executable can now be distributed safely." -ForegroundColor White
