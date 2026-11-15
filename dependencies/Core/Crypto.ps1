# Module: Crypto.ps1

function Unprotect-ToolkitConfig {
    param(
        [string]$Password,
        [string]$EncPath
    )

    if (-not (Test-Path $EncPath)) {
        throw "Encrypted config not found at '$EncPath'."
    }

    $payload = [Convert]::FromBase64String((Get-Content $EncPath -Raw).Trim())

    # File format: [16 bytes salt][16 bytes IV][ciphertext]
    $salt = $payload[0..15]
    $iv = $payload[16..31]
    $ciphertext = $payload[32..($payload.Length - 1)]

    # Derive AES key from password via PBKDF2
    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000, "SHA256")
    $aesKey = $derive.GetBytes(32)

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $aesKey
    $aes.IV = $iv
    $decryptor = $aes.CreateDecryptor()
    $plainBytes = $decryptor.TransformFinalBlock($ciphertext, 0, $ciphertext.Length)
    $aes.Dispose()

    $json = [System.Text.Encoding]::UTF8.GetString($plainBytes)
    return ($json | ConvertFrom-Json)
}

function Get-DriveSerial {
    param([string]$DriveLetter)
    try {
        $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        $disk = $partition | Get-Disk -ErrorAction SilentlyContinue
        if ($disk.SerialNumber) { return $disk.SerialNumber.Trim() }
    } catch { }
    return $null
}

function Get-ToolkitUsbSerial {
    # Prefer the serial captured at launch so the USB can be unplugged after startup
    param($Toolkit)
    if ($Toolkit.UsbSerial) { return $Toolkit.UsbSerial }
    return Get-DriveSerial -DriveLetter $Toolkit.UsbDrive
}

function Protect-CachedPassword {
    param([string]$Password, [string]$DriveSerial, [string]$UserPassword = '')
    $salt = [System.Text.Encoding]::UTF8.GetBytes("ToolkitUSB:$DriveSerial")
    $deriveStr = "USBBind:$DriveSerial"
    if ($UserPassword) { $deriveStr += ":$UserPassword" }
    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($deriveStr, $salt, 50000, "SHA256")
    $key = $derive.GetBytes(32)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.GenerateIV()
    $enc = $aes.CreateEncryptor()
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $encBytes = $enc.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
    $payload = New-Object byte[] ($aes.IV.Length + $encBytes.Length)
    [Array]::Copy($aes.IV, 0, $payload, 0, $aes.IV.Length)
    [Array]::Copy($encBytes, 0, $payload, $aes.IV.Length, $encBytes.Length)
    $aes.Dispose()
    return [Convert]::ToBase64String($payload)
}

function Unprotect-CachedPassword {
    param([string]$EncryptedData, [string]$DriveSerial, [string]$UserPassword = '')
    $salt = [System.Text.Encoding]::UTF8.GetBytes("ToolkitUSB:$DriveSerial")
    $deriveStr = "USBBind:$DriveSerial"
    if ($UserPassword) { $deriveStr += ":$UserPassword" }
    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($deriveStr, $salt, 50000, "SHA256")
    $key = $derive.GetBytes(32)
    $payload = [Convert]::FromBase64String($EncryptedData)
    $iv = $payload[0..15]
    $ciphertext = $payload[16..($payload.Length - 1)]
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.IV = $iv
    $dec = $aes.CreateDecryptor()
    $plainBytes = $dec.TransformFinalBlock($ciphertext, 0, $ciphertext.Length)
    $aes.Dispose()
    return [System.Text.Encoding]::UTF8.GetString($plainBytes)
}

function Protect-SfxPassword {
    param([string]$MainToolkitKey, [string]$SfxPassword)
    $salt = [System.Text.Encoding]::UTF8.GetBytes("ToolkitSFX:$SfxPassword")
    $deriveStr = "SFXBind:$SfxPassword"
    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($deriveStr, $salt, 50000, "SHA256")
    $key = $derive.GetBytes(32)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.GenerateIV()
    $enc = $aes.CreateEncryptor()
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($MainToolkitKey)
    $encBytes = $enc.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
    $payload = New-Object byte[] ($aes.IV.Length + $encBytes.Length)
    [Array]::Copy($aes.IV, 0, $payload, 0, $aes.IV.Length)
    [Array]::Copy($encBytes, 0, $payload, $aes.IV.Length, $encBytes.Length)
    $aes.Dispose()
    return [Convert]::ToBase64String($payload)
}

function Unprotect-SfxPassword {
    param([string]$EncryptedData, [string]$SfxPassword)
    $salt = [System.Text.Encoding]::UTF8.GetBytes("ToolkitSFX:$SfxPassword")
    $deriveStr = "SFXBind:$SfxPassword"
    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($deriveStr, $salt, 50000, "SHA256")
    $key = $derive.GetBytes(32)
    $payload = [Convert]::FromBase64String($EncryptedData)
    $iv = $payload[0..15]
    $ciphertext = $payload[16..($payload.Length - 1)]
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.IV = $iv
    $dec = $aes.CreateDecryptor()
    $plainBytes = $dec.TransformFinalBlock($ciphertext, 0, $ciphertext.Length)
    $aes.Dispose()
    return [System.Text.Encoding]::UTF8.GetString($plainBytes)
}

# ---------------------------------------------------------------------------
# Locked-kit primitives (vault, wizard secrets). Encrypt-then-MAC:
#   'TKB1' | salt(16) | iv(16) | AES-256-CBC ciphertext | HMAC-SHA256(everything before)(32)
# Keys come from PBKDF2-SHA256 over the secret (main key or passphrase) and the salt, split Enc/Mac.
# A wrong key, a wrong passphrase or any edited byte throws; nothing is ever half-decrypted.
# ---------------------------------------------------------------------------

function New-ToolkitMainKey {
    # 32 random bytes from the OS CSPRNG, base64. This key encrypts the vault of a locked kit.
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Get-ToolkitBlobKeys {
    param([string]$Secret, [byte[]]$Salt, [int]$Iterations)
    $d = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Secret, $Salt, $Iterations, 'SHA256')
    try { return @{ Enc = $d.GetBytes(32); Mac = $d.GetBytes(32) } } finally { $d.Dispose() }
}

function Protect-ToolkitBlob {
    # -Key: a main key from New-ToolkitMainKey (high entropy, so a low iteration count is enough).
    # -Passphrase: something a person typed (100k iterations).
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [string]$Key,
        [string]$Passphrase
    )
    $secret = if ($Key) { $Key } elseif ($Passphrase) { $Passphrase } else { throw 'Protect-ToolkitBlob needs -Key or -Passphrase.' }
    $iterations = if ($Key) { 1000 } else { 100000 }
    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $keys = Get-ToolkitBlobKeys -Secret $secret -Salt $salt -Iterations $iterations

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $keys.Enc
        $aes.GenerateIV()
        $cipher = $aes.CreateEncryptor().TransformFinalBlock($Bytes, 0, $Bytes.Length)
        $iv = $aes.IV
    } finally { $aes.Dispose() }

    $ms = New-Object System.IO.MemoryStream
    $magic = [System.Text.Encoding]::ASCII.GetBytes('TKB1')
    $ms.Write($magic, 0, 4); $ms.Write($salt, 0, 16); $ms.Write($iv, 0, 16); $ms.Write($cipher, 0, $cipher.Length)
    $body = $ms.ToArray()
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (, $keys.Mac)
    try { $tag = $hmac.ComputeHash($body) } finally { $hmac.Dispose() }
    $out = New-Object byte[] ($body.Length + 32)
    [Array]::Copy($body, 0, $out, 0, $body.Length)
    [Array]::Copy($tag, 0, $out, $body.Length, 32)
    return , $out
}

function Unprotect-ToolkitBlob {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [string]$Key,
        [string]$Passphrase
    )
    $secret = if ($Key) { $Key } elseif ($Passphrase) { $Passphrase } else { throw 'Unprotect-ToolkitBlob needs -Key or -Passphrase.' }
    $iterations = if ($Key) { 1000 } else { 100000 }
    if ($Bytes.Length -lt (4 + 16 + 16 + 16 + 32)) { throw 'The protected data is too small or corrupted.' }
    if ([System.Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'TKB1') { throw 'The protected data has an unknown format.' }
    $salt = New-Object byte[] 16; [Array]::Copy($Bytes, 4, $salt, 0, 16)
    $iv = New-Object byte[] 16;   [Array]::Copy($Bytes, 20, $iv, 0, 16)
    $keys = Get-ToolkitBlobKeys -Secret $secret -Salt $salt -Iterations $iterations

    $bodyLen = $Bytes.Length - 32
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (, $keys.Mac)
    try { $expected = $hmac.ComputeHash($Bytes, 0, $bodyLen) } finally { $hmac.Dispose() }
    $diff = 0
    for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($expected[$i] -bxor $Bytes[$bodyLen + $i]) }
    if ($diff -ne 0) { throw 'Wrong password, or the protected data was changed.' }

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $keys.Enc
        $aes.IV = $iv
        $plain = $aes.CreateDecryptor().TransformFinalBlock($Bytes, 36, $bodyLen - 36)
    } finally { $aes.Dispose() }
    return , $plain
}

function Protect-ToolkitDpapi {
    # Windows DPAPI, CurrentUser: only this Windows account on this PC can read it back.
    param([Parameter(Mandatory)][byte[]]$Bytes)
    Add-Type -AssemblyName System.Security
    $entropy = [System.Text.Encoding]::UTF8.GetBytes('TechnicianToolkit.Secrets')
    return , [System.Security.Cryptography.ProtectedData]::Protect($Bytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}

function Unprotect-ToolkitDpapi {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    Add-Type -AssemblyName System.Security
    $entropy = [System.Text.Encoding]::UTF8.GetBytes('TechnicianToolkit.Secrets')
    return , [System.Security.Cryptography.ProtectedData]::Unprotect($Bytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}
