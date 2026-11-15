# Module: Crypto.ps1

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

# ---------------------------------------------------------------------------
# Key files: .toolkit-key (USB) and .sfx-key (locked exe) hold the kit's main key, wrapped with the password.
#   Current format: base64 of a TKB1 blob (Protect-ToolkitBlob -Passphrase: random salt, 100k PBKDF2, HMAC).
#   Legacy format (core < 2.2.1): base64 of IV | AES-CBC, no MAC, salt derived from the password. Still
#   read, but a result is only accepted when it has the shape of a real main key, because without a MAC a
#   wrong password decrypts to garbage with valid padding about 1 time in 256.
# ---------------------------------------------------------------------------

function Test-ToolkitMainKeyShape {
    # New-ToolkitMainKey output (base64 of 32 bytes), or the 32-char alphanumeric key of core 2.0-2.1
    param([string]$Key)
    return [bool]($Key -cmatch '^[A-Za-z0-9+/]{43}=$' -or $Key -cmatch '^[A-Za-z0-9]{32}$')
}

function Protect-ToolkitKeyFile {
    param([Parameter(Mandatory)][string]$MainKey, [Parameter(Mandatory)][string]$Passphrase)
    $blob = Protect-ToolkitBlob -Bytes ([System.Text.Encoding]::UTF8.GetBytes($MainKey)) -Passphrase $Passphrase
    return [Convert]::ToBase64String($blob)
}

function Unprotect-ToolkitKeyFile {
    # The main key, or a throw (wrong password / changed file). -LegacySalt/-LegacySecret: the old format's inputs.
    param(
        [Parameter(Mandatory)][string]$EncryptedData,
        [Parameter(Mandatory)][string]$Passphrase,
        [Parameter(Mandatory)][string]$LegacySalt,
        [Parameter(Mandatory)][string]$LegacySecret
    )
    $payload = [Convert]::FromBase64String($EncryptedData.Trim())
    if ($payload.Length -ge 4 -and [System.Text.Encoding]::ASCII.GetString($payload, 0, 4) -eq 'TKB1') {
        $key = [System.Text.Encoding]::UTF8.GetString((Unprotect-ToolkitBlob -Bytes $payload -Passphrase $Passphrase))
    } else {
        if ($payload.Length -lt 32) { throw 'The key file is too small or corrupted.' }
        $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($LegacySecret, [System.Text.Encoding]::UTF8.GetBytes($LegacySalt), 50000, 'SHA256')
        try { $aesKey = $derive.GetBytes(32) } finally { $derive.Dispose() }
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.Key = $aesKey
            $aes.IV = [byte[]]$payload[0..15]
            $plain = $aes.CreateDecryptor().TransformFinalBlock($payload, 16, $payload.Length - 16)
        } finally { $aes.Dispose() }
        $key = [System.Text.Encoding]::UTF8.GetString($plain)
    }
    if (-not (Test-ToolkitMainKeyShape $key)) { throw 'Wrong password, or the key file was changed.' }
    return $key
}

function Get-ToolkitUsbPassphrase {
    param([string]$DriveSerial, [string]$UserPassword)
    $s = "USBBind:$DriveSerial"
    if ($UserPassword) { $s += ":$UserPassword" }
    return $s
}

function Protect-CachedPassword {
    # .toolkit-key: the main key bound to this USB's serial and the USB password
    param([string]$Password, [string]$DriveSerial, [string]$UserPassword = '')
    return Protect-ToolkitKeyFile -MainKey $Password -Passphrase (Get-ToolkitUsbPassphrase $DriveSerial $UserPassword)
}

function Unprotect-CachedPassword {
    param([string]$EncryptedData, [string]$DriveSerial, [string]$UserPassword = '')
    $secret = Get-ToolkitUsbPassphrase $DriveSerial $UserPassword
    return Unprotect-ToolkitKeyFile -EncryptedData $EncryptedData -Passphrase $secret -LegacySalt "ToolkitUSB:$DriveSerial" -LegacySecret $secret
}

function Protect-SfxPassword {
    # .sfx-key: the main key wrapped with the locked exe's password
    param([string]$MainToolkitKey, [string]$SfxPassword)
    return Protect-ToolkitKeyFile -MainKey $MainToolkitKey -Passphrase $SfxPassword
}

function Unprotect-SfxPassword {
    param([string]$EncryptedData, [string]$SfxPassword)
    return Unprotect-ToolkitKeyFile -EncryptedData $EncryptedData -Passphrase $SfxPassword -LegacySalt "ToolkitSFX:$SfxPassword" -LegacySecret "SFXBind:$SfxPassword"
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
