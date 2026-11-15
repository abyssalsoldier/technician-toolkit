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
if ($password.Length -lt 4) {
    Write-Host "ERROR: Password must be at least 4 characters." -ForegroundColor Red
    exit 1
}
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$outPath = if ($OutputPath) { $OutputPath } else { Read-Host "Enter output path (e.g., C:\Users\Public\Desktop)" }
if (-not (Test-Path $outPath)) {
    Write-Host "Output path not found." -ForegroundColor Red
    exit 1
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
$csharpCode = @"
using System;
using System.IO;
using System.IO.Compression;
using System.Diagnostics;
using System.Reflection;

namespace EndpointToolkit
{
    class Program
    {
        static void Main(string[] args)
        {
            string exePath = Assembly.GetExecutingAssembly().Location;
            string tempDir = Path.Combine(Path.GetTempPath(), "EndpointToolkit_SC");
            
            if (Directory.Exists(tempDir)) {
                try { Directory.Delete(tempDir, true); } catch { }
            }
            Directory.CreateDirectory(tempDir);
            // Only this user, SYSTEM and Administrators may open the extracted kit
            // (matters under ConnectWise/SYSTEM, where TEMP is the shared C:\Windows\Temp)
            try {
                var sec = new System.Security.AccessControl.DirectorySecurity();
                sec.SetAccessRuleProtection(true, false);
                var inherit = System.Security.AccessControl.InheritanceFlags.ContainerInherit | System.Security.AccessControl.InheritanceFlags.ObjectInherit;
                var full = System.Security.AccessControl.FileSystemRights.FullControl;
                var allow = System.Security.AccessControl.AccessControlType.Allow;
                var none = System.Security.AccessControl.PropagationFlags.None;
                sec.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(System.Security.Principal.WindowsIdentity.GetCurrent().User, full, inherit, none, allow));
                sec.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(new System.Security.Principal.SecurityIdentifier(System.Security.Principal.WellKnownSidType.LocalSystemSid, null), full, inherit, none, allow));
                sec.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(new System.Security.Principal.SecurityIdentifier(System.Security.Principal.WellKnownSidType.BuiltinAdministratorsSid, null), full, inherit, none, allow));
                Directory.SetAccessControl(tempDir, sec);
            } catch { }
            
            Console.WriteLine("Extracting Secure Toolkit...");
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
                        archive.ExtractToDirectory(tempDir);
                    }
                }
                all = null;
            } catch (Exception ex) {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine("Extraction failed: " + ex.Message);
                Console.ResetColor();
                Console.ReadKey();
                return;
            }

            string setupScript = Path.Combine(tempDir, @"dependencies\Invoke-EndpointSetup.ps1");
            ProcessStartInfo psi = new ProcessStartInfo {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + setupScript + "\"",
                UseShellExecute = true,
                Verb = "RunAs"
            };
            try {
                Process.Start(psi);
            } catch (Exception ex) {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine("Launch failed: " + ex.Message);
                Console.ResetColor();
                Console.ReadKey();
            }
        }
    }
}
"@

$stubPath = Join-Path $env:TEMP "ToolkitStub-$(Get-Date -Format 'yyyyMMdd_HHmmss').exe"
Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies "System.IO.Compression", "System.IO.Compression.FileSystem" -OutputAssembly $stubPath -OutputType ConsoleApplication

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
Remove-Item $stubPath -Force

Write-Host "`nSUCCESS! Locked toolkit exported to: $targetExe" -ForegroundColor Green
Write-Host "This executable can now be distributed safely." -ForegroundColor White
