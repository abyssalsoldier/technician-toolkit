# Core: SafeFileSystem.ps1
# Folder helpers for elevated / SYSTEM runs. Under ConnectWise Toolbox (SYSTEM) %TEMP% is the shared
# C:\Windows\Temp, where every local user may create folders and files, and inside folders created there
# (ACE "Users:(CI)(S,WD,AD,X)"). Any local user may also create folders in C:\. So a work folder the toolkit
# makes there must be private from the moment it exists, fixed names must not be trusted, and deletes must
# never follow a junction/symlink a user planted (that turns cleanup into "delete any file as SYSTEM").
#
# Function definitions only: this file is dot-sourced at every launch and in every runspace.
# Works in Windows PowerShell 5.1 (.NET Framework) and PowerShell 7 (.NET).

function Get-ToolkitTrustedSids {
    # The accounts a toolkit work folder may belong to: this account, SYSTEM, Administrators
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $admins = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    return @($me, $system, $admins)
}

function New-ToolkitDirectorySecurity {
    # Protected DACL (no inherited entries): Full Control for the trusted accounts.
    # -ReadSid: also Read & Execute for that account (e.g. Authenticated Users on report folders).
    param([System.Security.Principal.SecurityIdentifier]$ReadSid)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in Get-ToolkitTrustedSids) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, $none, $allow)))
    }
    if ($ReadSid) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($ReadSid, 'ReadAndExecute', $inherit, $none, $allow)))
    }
    return , $acl
}

function Test-ToolkitTrustedDirectory {
    # $true when Path is a real folder (not a junction/symlink) owned by a trusted account.
    # -RequireEmpty: and it has no entries.
    param([Parameter(Mandatory)][string]$Path, [switch]$RequireEmpty)
    try {
        $di = New-Object System.IO.DirectoryInfo($Path)
        if (-not $di.Exists) { return $false }
        if ($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
        $owner = (Get-Acl -LiteralPath $di.FullName -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier])
        if (-not (@(Get-ToolkitTrustedSids) | Where-Object { $_.Equals($owner) })) { return $false }
        if ($RequireEmpty -and @($di.EnumerateFileSystemInfos()).Count -gt 0) { return $false }
        return $true
    } catch { return $false }
}

function New-ToolkitSecuredDirectory {
    # Creates Path with Security applied at creation (no window in which it has the parent's ACL).
    # Throws when Path already exists or the result is not a fresh folder owned by a trusted account
    # (someone created it first). Returns the full path.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Security.AccessControl.DirectorySecurity]$Security
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $full) { throw "$full already exists." }
    $di = New-Object System.IO.DirectoryInfo($full)
    $aclExt = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($aclExt -and $aclExt.GetMethod('Create', [type[]]@([System.IO.DirectoryInfo], [System.Security.AccessControl.DirectorySecurity]))) {
        $aclExt::Create($di, $Security)                        # PowerShell 7 / .NET
    } else {
        [void][System.IO.Directory]::CreateDirectory($full, $Security)   # Windows PowerShell 5.1 / .NET Framework
    }
    # Both calls also "succeed" on a folder that appeared in the meantime: only accept our own, empty one
    if (-not (Test-ToolkitTrustedDirectory -Path $full -RequireEmpty)) {
        throw "$full could not be created safely (it was created by another account or is a link)."
    }
    return $full
}

function New-ToolkitPrivateDirectory {
    # A new folder only this account, SYSTEM and Administrators can open. Use for every work folder under
    # %TEMP%. Use a unique name (a GUID): a fixed name can be taken first, and then this throws.
    param([Parameter(Mandatory)][string]$Path)
    return New-ToolkitSecuredDirectory -Path $Path -Security (New-ToolkitDirectorySecurity)
}

function Get-ToolkitInfoPath {
    # C:\_INFO\<Module>: the durable report folder. Created with Administrators/SYSTEM Full Control and
    # Authenticated Users Read & Execute. Refuses (throws) when C:\_INFO or the module folder is a
    # junction/symlink or belongs to an untrusted account (another user may have created it first to
    # redirect the toolkit's writes). Existing trusted folders get the same protected ACL (best effort).
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Module,
        [string]$Base = 'C:\_INFO'
    )
    $authUsers = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid, $null)
    $base = [System.IO.Path]::GetFullPath($Base).TrimEnd('\')
    foreach ($dir in $base, (Join-Path $base $Module)) {
        $security = New-ToolkitDirectorySecurity -ReadSid $authUsers
        if (-not (Test-Path -LiteralPath $dir)) {
            try { $null = New-ToolkitSecuredDirectory -Path $dir -Security $security }
            catch { throw "Report folder $dir could not be created safely: $($_.Exception.Message)" }
            continue
        }
        if (-not (Test-ToolkitTrustedDirectory -Path $dir)) {
            throw "Report folder $dir is a link or belongs to another account, so nothing was written there. Delete it as an administrator and try again."
        }
        try {
            if (-not (Get-Acl -LiteralPath $dir).AreAccessRulesProtected) { Set-Acl -LiteralPath $dir -AclObject $security -ErrorAction Stop }
        } catch { }
    }
    return (Join-Path $base $Module)
}

function Remove-ToolkitTree {
    # Recursive delete that never follows links: a junction or symlink found anywhere in the tree is
    # removed as a link, and what it points to is left alone. (Windows PowerShell 5.1 Remove-Item -Recurse
    # can descend into a junction inside a folder and delete the target's files.) Best effort, never throws.
    param([Parameter(Mandatory)][string]$LiteralPath)
    try {
        $full = [System.IO.Path]::GetFullPath($LiteralPath)
        if ([System.IO.Directory]::Exists($full)) { $item = New-Object System.IO.DirectoryInfo($full) }
        elseif ([System.IO.File]::Exists($full)) { $item = New-Object System.IO.FileInfo($full) }
        else { return }
        Remove-ToolkitTreeItem -Item $item
    } catch { }
}

function Remove-ToolkitTreeItem {
    # Internal helper for Remove-ToolkitTree
    param([System.IO.FileSystemInfo]$Item)
    $isLink = [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    try {
        if ($Item -is [System.IO.DirectoryInfo]) {
            if (-not $isLink) {
                foreach ($child in @($Item.EnumerateFileSystemInfos())) { Remove-ToolkitTreeItem -Item $child }
                if ($Item.Attributes -band [System.IO.FileAttributes]::ReadOnly) { $Item.Attributes = $Item.Attributes -bxor [System.IO.FileAttributes]::ReadOnly }
            }
            [System.IO.Directory]::Delete($Item.FullName, $false)   # on a junction: removes the link only
        } else {
            if (-not $isLink -and $Item.IsReadOnly) { $Item.IsReadOnly = $false }
            [System.IO.File]::Delete($Item.FullName)                # on a symlink: removes the link only
        }
    } catch { }
}
