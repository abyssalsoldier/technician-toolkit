# Module: Storage-Management.ps1 — WizTree-style disk usage browser (folder tree + list + treemap)

function Register-StorageManagement {
    @{
        Name         = 'Storage-Management'
        Label        = 'Storage Management'
        Description  = 'Scan drives and folders to see what is using disk space, with a WizTree-style treemap.'
        RequiresAuth = $false
        SortOrder    = 35
        EntryPoint   = 'Invoke-StorageManagement'
        UIDefinition = 'Get-StorageManagementUI'
    }
}

function Invoke-StorageManagement {
    Write-Log 'Storage Management module invoked.' -Level Info
}

# ============================================================================
# Native interop for raw NTFS volume access (MFT fast path)
#
# The per-record MFT parsing loop (fixup repair + attribute walking) is
# compiled C# rather than PowerShell: on a large drive that loop can run
# for well over a million records, and interpreted PowerShell's per-call
# overhead at that scale dominates wall-clock time even though the actual
# disk I/O is fast. Compiling it via Add-Type (same mechanism already used
# for the P/Invoke declarations) keeps this a single self-contained .ps1
# file with no external binary, while running the hot loop as JIT-compiled
# code instead of interpreted script.
#
# Add-Type itself can be blocked by policy (Constrained Language Mode,
# AppLocker/WDAC disallowing dynamic code) on locked-down machines, so this
# is wrapped in try/catch — $script:DsaNativeAvailable tells the rest of the
# module whether the MFT fast path can be attempted at all; when it can't,
# every volume just uses the enumeration scanner.
# ============================================================================

$script:DsaNativeAvailable = $false
try {
    if (-not ('Dsa.MftParser' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Dsa
{
    public static class NativeMethods
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateFile(
            string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes,
            uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "ReadFile")]
        public static extern bool ReadFilePtr(
            IntPtr hFile, IntPtr lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetFilePointerEx(
            IntPtr hFile, long liDistanceToMove, out long lpNewFilePointer, uint dwMoveMethod);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr VirtualAlloc(IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool VirtualFree(IntPtr lpAddress, UIntPtr dwSize, uint dwFreeType);

        private const uint MEM_COMMIT = 0x1000;
        private const uint MEM_RESERVE = 0x2000;
        private const uint MEM_RELEASE = 0x8000;
        private const uint PAGE_READWRITE = 0x04;

        // The volume handle is opened with FILE_FLAG_NO_BUFFERING (see Read-DsaMftTree) —
        // buffered/cached reads on a raw volume handle turned out to run at a small
        // fraction of the drive's real sequential throughput, which was the actual
        // scan-time bottleneck, not the record-parsing loop below. Unbuffered reads
        // require both the file offset and the read length to be sector-aligned, and
        // the destination buffer's memory address to be aligned too — VirtualAlloc
        // always returns page-aligned (4096-byte) memory, which satisfies every real
        // sector size (512 or 4096) a Windows volume uses, so it's simpler and safer
        // here than trying to align a slice of a managed array.
        public static byte[] ReadAligned(IntPtr handle, long offset, int length)
        {
            int alignedLength = ((length + 4095) / 4096) * 4096;
            IntPtr buf = VirtualAlloc(IntPtr.Zero, (UIntPtr)alignedLength, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (buf == IntPtr.Zero) throw new InvalidOperationException("VirtualAlloc failed");

            try
            {
                long newPos;
                if (!SetFilePointerEx(handle, offset, out newPos, 0))
                    throw new InvalidOperationException("SetFilePointerEx failed, Win32 error " + Marshal.GetLastWin32Error());

                uint bytesRead;
                if (!ReadFilePtr(handle, buf, (uint)alignedLength, out bytesRead, IntPtr.Zero))
                    throw new InvalidOperationException("ReadFile failed, Win32 error " + Marshal.GetLastWin32Error());

                byte[] result = new byte[length];
                Marshal.Copy(buf, result, 0, length);
                return result;
            }
            finally
            {
                VirtualFree(buf, UIntPtr.Zero, MEM_RELEASE);
            }
        }
    }

    // A single hard-link location for a file: one $FILE_NAME attribute = one place the
    // file appears in the folder tree. Directories can only ever have one (NTFS doesn't
    // allow directory hard links); ordinary files commonly have more than one — Windows
    // makes heavy use of this for driver/component files (e.g. System32\drivers entries
    // that are really hard-linked from a WinSxS component folder). Keeping only "the
    // best" name per record (the original, simpler design) silently dropped every file
    // whose real folder-tree location wasn't the one that happened to win — verified
    // against a real machine, that under-reported System32\drivers by about 73%.
    public class MftFileLink
    {
        public long ParentRecordNumber;
        public string Name;
    }

    public class MftRecordInfo
    {
        public long RecordNumber;
        public List<MftFileLink> Links = new List<MftFileLink>();
        public bool IsDirectory;
        public long Size;
        public long FileCount;     // directories only, filled in by BuildHierarchy
        public long FolderCount;   // directories only, filled in by BuildHierarchy
        public long ModifiedTicks;   // raw FILETIME value; converted to DateTime lazily on the PowerShell side
    }

    // Parses NTFS $MFT records in bulk. PowerShell hands it one raw chunk of
    // consecutive records at a time (already read from disk); this does the
    // per-record fixup + attribute parsing natively and accumulates results,
    // so PowerShell only pays interpreter overhead once per chunk instead of
    // once per record.
    public class MftParser
    {
        public Dictionary<long, MftRecordInfo> Records = new Dictionary<long, MftRecordInfo>();
        public Dictionary<long, List<long>> ChildrenByParent = new Dictionary<long, List<long>>();
        public long FoldersFound = 0;
        public long FilesFound = 0;

        // Groups records by parent and computes each directory's aggregate Size/FileCount/
        // FolderCount, all natively. Doing this in PowerShell (creating one PSCustomObject
        // per record just to sum up a parent's children) was the actual remaining
        // bottleneck after the parse loop itself was compiled — building a ~940K-node
        // PowerShell object tree eagerly took well over a minute on its own. This runs
        // once after all chunks are parsed; PowerShell only ever materializes a node
        // object lazily, for whichever folder is actually being displayed.
        //
        // Uses an explicit stack instead of recursion for the post-order walk — a real
        // stack overflow in compiled code kills the process outright (unlike a
        // PowerShell recursion error), so this can't risk that on a deep folder tree.
        public void BuildHierarchy(long rootRecordNumber)
        {
            foreach (var kv in Records)
            {
                if (kv.Key == rootRecordNumber) continue;
                MftRecordInfo info = kv.Value;
                // A hard-linked file is added under EVERY one of its valid parent
                // folders, not just one — see the MftFileLink comment above.
                foreach (MftFileLink link in info.Links)
                {
                    MftRecordInfo parent;
                    if (!Records.TryGetValue(link.ParentRecordNumber, out parent) || !parent.IsDirectory) continue;

                    List<long> siblings;
                    if (!ChildrenByParent.TryGetValue(link.ParentRecordNumber, out siblings))
                    {
                        siblings = new List<long>();
                        ChildrenByParent[link.ParentRecordNumber] = siblings;
                    }
                    siblings.Add(kv.Key);
                }
            }

            var stack = new Stack<KeyValuePair<long, bool>>();
            stack.Push(new KeyValuePair<long, bool>(rootRecordNumber, false));

            while (stack.Count > 0)
            {
                var top = stack.Pop();
                long recNum = top.Key;
                bool childrenDone = top.Value;

                MftRecordInfo node;
                if (!Records.TryGetValue(recNum, out node) || !node.IsDirectory) continue;

                List<long> children;
                bool hasChildren = ChildrenByParent.TryGetValue(recNum, out children);

                if (!childrenDone)
                {
                    stack.Push(new KeyValuePair<long, bool>(recNum, true));
                    if (hasChildren)
                    {
                        foreach (long childId in children)
                        {
                            MftRecordInfo child;
                            if (Records.TryGetValue(childId, out child) && child.IsDirectory)
                                stack.Push(new KeyValuePair<long, bool>(childId, false));
                        }
                    }
                    continue;
                }

                long totalSize = 0, totalFiles = 0, totalFolders = 0;
                if (hasChildren)
                {
                    foreach (long childId in children)
                    {
                        MftRecordInfo child;
                        if (!Records.TryGetValue(childId, out child)) continue;
                        totalSize += child.Size;
                        if (child.IsDirectory) { totalFolders += 1 + child.FolderCount; totalFiles += child.FileCount; }
                        else { totalFiles += 1; }
                    }
                }
                node.Size = totalSize;
                node.FileCount = totalFiles;
                node.FolderCount = totalFolders;
            }
        }

        // Lets the tree-view UI decide whether to show an expand arrow without having
        // to materialize any PowerShell node objects just to find out.
        public bool HasDirectoryChild(long recordNumber)
        {
            List<long> children;
            if (!ChildrenByParent.TryGetValue(recordNumber, out children)) return false;
            foreach (long id in children)
            {
                MftRecordInfo info;
                if (Records.TryGetValue(id, out info) && info.IsDirectory) return true;
            }
            return false;
        }

        // Flattens the whole scanned volume (not just one folder) for the "Top Largest
        // Files/Folders" report modes — a plain sort over the already-built Records
        // dictionary, no tree walk needed.
        public List<MftRecordInfo> GetTopItems(bool foldersOnly, int top)
        {
            var filtered = new List<MftRecordInfo>();
            foreach (MftRecordInfo info in Records.Values)
            {
                bool wantThis = foldersOnly ? info.IsDirectory : !info.IsDirectory;
                if (wantThis) filtered.Add(info);
            }
            filtered.Sort((a, b) => b.Size.CompareTo(a.Size));
            if (filtered.Count > top) filtered = filtered.GetRange(0, top);
            return filtered;
        }

        // Returns the biggest N direct children of one folder, natively — used by the
        // treemap so a folder with hundreds of items only ever materializes PowerShell
        // node objects for the handful actually big enough to draw, instead of every
        // child just to find out most of them round to sub-pixel rectangles anyway.
        public List<MftRecordInfo> GetTopChildren(long parentRecordNumber, int top)
        {
            var result = new List<MftRecordInfo>();
            List<long> childIds;
            if (!ChildrenByParent.TryGetValue(parentRecordNumber, out childIds)) return result;
            foreach (long id in childIds)
            {
                MftRecordInfo info;
                if (Records.TryGetValue(id, out info) && info.Size > 0) result.Add(info);
            }
            result.Sort((a, b) => b.Size.CompareTo(a.Size));
            if (result.Count > top) result = result.GetRange(0, top);
            return result;
        }

        public static void RepairFixup(byte[] record, int bytesPerSector)
        {
            int usaOffset = BitConverter.ToUInt16(record, 4);
            int usaCount = BitConverter.ToUInt16(record, 6);
            if (usaCount < 2) return;

            for (int i = 1; i < usaCount; i++)
            {
                int sectorEnd = i * bytesPerSector;
                if (sectorEnd > record.Length) break;
                int checkOffset = sectorEnd - 2;
                int fixupOffset = usaOffset + (i * 2);
                if (fixupOffset + 1 >= record.Length) break;
                record[checkOffset] = record[fixupOffset];
                record[checkOffset + 1] = record[fixupOffset + 1];
            }
        }

        public void ParseChunk(byte[] buffer, int recordCount, int recordSize, int bytesPerSector, long startRecordNumber)
        {
            byte[] rec = new byte[recordSize];
            for (int i = 0; i < recordCount; i++)
            {
                Array.Copy(buffer, i * recordSize, rec, 0, recordSize);
                RepairFixup(rec, bytesPerSector);
                MftRecordInfo info = ParseRecord(rec, startRecordNumber + i);
                if (info != null)
                {
                    Records[info.RecordNumber] = info;
                    if (info.IsDirectory) FoldersFound++; else FilesFound++;
                }
            }
        }

        private static MftRecordInfo ParseRecord(byte[] record, long recordNumber)
        {
            if (record.Length < 0x30) return null;
            if (record[0] != (byte)'F' || record[1] != (byte)'I' || record[2] != (byte)'L' || record[3] != (byte)'E') return null;

            ushort flags = BitConverter.ToUInt16(record, 0x16);
            if ((flags & 0x0001) == 0) return null; // not in use
            bool isDirectory = (flags & 0x0002) != 0;

            int attrOffset = BitConverter.ToUInt16(record, 0x14);
            int recordLength = record.Length;

            List<MftFileLink> links = new List<MftFileLink>();
            long size = 0;
            long modifiedTicks = 0;

            while (attrOffset < recordLength - 8)
            {
                uint attrType = BitConverter.ToUInt32(record, attrOffset);
                if (attrType == 0xFFFFFFFF) break;
                uint attrLen = BitConverter.ToUInt32(record, attrOffset + 4);
                if (attrLen == 0 || attrOffset + attrLen > recordLength) break;
                byte nonResident = record[attrOffset + 8];
                byte nameLenBytes = record[attrOffset + 9];

                if (attrType == 0x30 && nonResident == 0)
                {
                    // $FILE_NAME (always resident) — one attribute per hard-link location.
                    int contentOffset = BitConverter.ToUInt16(record, attrOffset + 0x14);
                    int b = attrOffset + contentOffset;
                    if (b + 0x42 <= recordLength)
                    {
                        ulong parentRef = BitConverter.ToUInt64(record, b);
                        long parentRecNum = (long)(parentRef & 0xFFFFFFFFFFFF);
                        byte nameLen = record[b + 0x40];
                        byte nameType = record[b + 0x41];

                        // Skip DOS-only 8.3 short names (namespace 2) — every real hard-link
                        // location has exactly one non-DOS name (POSIX/Win32/Win32&DOS); a
                        // sibling DOS-only attribute for that same location just duplicates it.
                        if (nameType != 2 && b + 0x42 + (nameLen * 2) <= recordLength)
                        {
                            string linkName = Encoding.Unicode.GetString(record, b + 0x42, nameLen * 2);
                            links.Add(new MftFileLink { ParentRecordNumber = parentRecNum, Name = linkName });
                            if (modifiedTicks == 0) modifiedTicks = BitConverter.ToInt64(record, b + 0x10);
                        }
                    }
                }
                else if (attrType == 0x80 && nameLenBytes == 0)
                {
                    // Unnamed $DATA — file size. Non-resident header carries RealSize directly,
                    // no need to walk data runs just to learn how big the file is.
                    if (nonResident == 0)
                    {
                        uint contentLen = BitConverter.ToUInt32(record, attrOffset + 0x10);
                        size = contentLen;
                    }
                    else if (attrOffset + 0x38 <= recordLength)
                    {
                        size = (long)BitConverter.ToUInt64(record, attrOffset + 0x30);
                    }
                }

                attrOffset += (int)attrLen;
            }

            if (links.Count == 0) return null;

            MftRecordInfo info = new MftRecordInfo();
            info.RecordNumber = recordNumber;
            info.Links = links;
            info.IsDirectory = isDirectory;
            info.Size = size;
            info.ModifiedTicks = modifiedTicks;
            return info;
        }
    }
}
'@
    }
    $script:DsaNativeAvailable = $true
} catch {
    Write-Warning "Storage Management: native MFT reader unavailable ($($_.Exception.Message)) - drives will use the standard recursive scan instead."
    $script:DsaNativeAvailable = $false
}

# ============================================================================
# Shared data model + formatting helpers
# ============================================================================

function New-DsaNode {
    param(
        [string]$Name,
        [string]$FullPath = $null,
        [bool]$IsDirectory,
        [long]$Size = 0,
        [Nullable[datetime]]$LastWriteTime = $null
    )
    # MftParser/MftRecordNumber/_MaterializedChildren/IsThisPcRoot are declared here
    # (rather than bolted on later via Add-Member) purely for speed: Add-Member goes
    # through PowerShell's ETS reflection machinery and is measurably slower than a
    # plain property set, and this constructor runs once per node materialized —
    # potentially thousands of times during a single treemap render.
    [pscustomobject]@{
        Name                  = $Name
        FullPath              = $FullPath
        IsDirectory           = $IsDirectory
        Size                  = [long]$Size
        FileCount             = 0
        FolderCount           = 0
        LastWriteTime         = $LastWriteTime
        Children              = [System.Collections.Generic.List[object]]::new()
        Parent                = $null
        TreeViewItem          = $null
        MftParser             = $null
        MftRecordNumber       = $null
        _MaterializedChildren = $null
        IsThisPcRoot          = $false
    }
}

function Format-DsaSize {
    param([long]$Bytes)
    $units = 'B', 'KB', 'MB', 'GB', 'TB', 'PB'
    if ($Bytes -lt 1024) { return "$Bytes B" }
    $val = [double]$Bytes
    $i = 0
    while ($val -ge 1024 -and $i -lt $units.Count - 1) { $val /= 1024; $i++ }
    return "{0:N2} {1}" -f $val, $units[$i]
}

$script:DsaExtensionCategories = @{
    '.mp4' = 'Video'; '.mkv' = 'Video'; '.avi' = 'Video'; '.mov' = 'Video'; '.wmv' = 'Video'; '.flv' = 'Video'; '.m4v' = 'Video'; '.webm' = 'Video'
    '.jpg' = 'Image'; '.jpeg' = 'Image'; '.png' = 'Image'; '.gif' = 'Image'; '.bmp' = 'Image'; '.heic' = 'Image'; '.tiff' = 'Image'; '.webp' = 'Image'; '.svg' = 'Image'; '.ico' = 'Image'
    '.zip' = 'Archive'; '.rar' = 'Archive'; '.7z' = 'Archive'; '.iso' = 'Archive'; '.tar' = 'Archive'; '.gz' = 'Archive'; '.cab' = 'Archive'; '.bz2' = 'Archive'; '.xz' = 'Archive'
    '.exe' = 'Installer'; '.msi' = 'Installer'; '.msix' = 'Installer'; '.msu' = 'Installer'; '.appx' = 'Installer'
    '.doc' = 'Document'; '.docx' = 'Document'; '.pdf' = 'Document'; '.xls' = 'Document'; '.xlsx' = 'Document'
    '.ppt' = 'Document'; '.pptx' = 'Document'; '.txt' = 'Document'; '.rtf' = 'Document'; '.csv' = 'Document'; '.md' = 'Document'
    '.mp3' = 'Audio'; '.wav' = 'Audio'; '.flac' = 'Audio'; '.aac' = 'Audio'; '.ogg' = 'Audio'; '.wma' = 'Audio'; '.m4a' = 'Audio'
    '.js' = 'Code'; '.ts' = 'Code'; '.py' = 'Code'; '.cs' = 'Code'; '.java' = 'Code'; '.cpp' = 'Code'; '.c' = 'Code'; '.h' = 'Code'
    '.json' = 'Code'; '.xml' = 'Code'; '.html' = 'Code'; '.css' = 'Code'; '.ps1' = 'Code'; '.psm1' = 'Code'; '.sh' = 'Code'
    '.yml' = 'Code'; '.yaml' = 'Code'; '.sql' = 'Code'; '.go' = 'Code'; '.rs' = 'Code'; '.php' = 'Code'; '.rb' = 'Code'
    '.dll' = 'System'; '.sys' = 'System'; '.ini' = 'System'; '.cfg' = 'System'; '.config' = 'System'; '.dat' = 'System'; '.bak' = 'System'; '.tmp' = 'System'; '.cache' = 'System'
    '.db' = 'Database'; '.sqlite' = 'Database'; '.sqlite3' = 'Database'; '.mdb' = 'Database'; '.accdb' = 'Database'
    '.log' = 'Log'
    '.ttf' = 'Font'; '.otf' = 'Font'; '.woff' = 'Font'; '.woff2' = 'Font'
}
$script:DsaCategoryColors = @{
    'Video' = '#F38BA8'; 'Image' = '#F5C2E7'; 'Archive' = '#FAB387'
    'Installer' = '#F9E2AF'; 'Document' = '#94E2D5'; 'Audio' = '#EBA0AC'
    'Code' = '#74C7EC'; 'System' = '#F5E0DC'; 'Database' = '#CBA6F7'
    'Log' = '#A6ADC8'; 'Font' = '#89DCEB'; 'Other' = '#9399B2'
}
# Validated against this app's dark treemap surface (#1E1E2E) with the dataviz
# skill's contrast checker: lightness band, chroma floor, adjacent CVD separation,
# and normal-vision separation all pass (node scripts/validate_palette.js).
# Deliberately more saturated than the pastel file-category colors above, so
# folders and files read as two different visual families at a glance, not just
# different-but-similar hues.
$script:DsaFolderColors = @(
    '#3987e5', '#d95926', '#199e70', '#c98500', '#d55181', '#008300', '#9085e9', '#e66767',
    '#6c6fd6', '#1ba8a8', '#5e8a12', '#1a7ba0', '#b34d90'
)

function Get-DsaStableHash {
    # A plain DJB2-style hash instead of .NET's [string]::GetHashCode(), which is
    # randomized per process (hash-flooding protection) — that would make the same
    # folder get a different color every time the app restarts. This is only used
    # to pick a color, not for anything security-sensitive, so determinism matters
    # more here than cryptographic hash quality.
    param([string]$Text)
    $hash = 5381
    foreach ($ch in $Text.ToCharArray()) { $hash = (($hash * 33) + [int]$ch) -band 0x7FFFFFFF }
    return $hash
}

function Get-DsaItemColor {
    param($Node, [int]$DepthIndex = 0)
    if ($Node.IsDirectory) {
        # Colored by the folder's own identity (path if known, else name), not by
        # render depth — depth-based coloring made every folder at the same nesting
        # level (e.g. every top-level folder on a drive) render as the identical
        # color, which is what made the treemap unreadable: large areas of solid
        # indistinguishable blue with only thin gridlines between different folders.
        $key = if ($Node.FullPath) { $Node.FullPath } else { $Node.Name }
        $hash = Get-DsaStableHash -Text $key
        return $script:DsaFolderColors[$hash % $script:DsaFolderColors.Count]
    }
    $ext = [System.IO.Path]::GetExtension($Node.Name)
    if ($ext) { $ext = $ext.ToLowerInvariant() }
    $cat = $script:DsaExtensionCategories[$ext]
    if (-not $cat) { $cat = 'Other' }
    return $script:DsaCategoryColors[$cat]
}

function Get-DsaPercentBarText {
    param([double]$Percent)
    $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $filled = [int][Math]::Round($Percent / 100 * 14)
    ('{0}{1} {2:N1}%' -f ('▓' * $filled), ('░' * (14 - $filled)), $Percent)
}

function New-DsaBrush {
    param([string]$Hex)
    New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

# ============================================================================
# Enumeration scanner (fallback path — used for non-NTFS volumes and whenever
# the MFT fast path fails for any reason)
# ============================================================================

function Measure-DsaDirectory {
    param(
        [string]$Path,
        [hashtable]$ProgressState,
        [ref]$CancelFlagRef,
        $ParentNode = $null
    )

    $dirInfo = [System.IO.DirectoryInfo]::new($Path)
    $node = New-DsaNode -Name $dirInfo.Name -FullPath $dirInfo.FullName -IsDirectory $true -LastWriteTime $dirInfo.LastWriteTime
    $node.Parent = $ParentNode
    if (-not $node.Name) { $node.Name = $dirInfo.FullName }

    try {
        $entries = $dirInfo.EnumerateFileSystemInfos()
    } catch {
        $ProgressState.AccessDenied++
        return $node
    }

    try {
        foreach ($entry in $entries) {
            if ($CancelFlagRef.Value) { break }

            $isReparse = ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

            if ($entry -is [System.IO.DirectoryInfo]) {
                $ProgressState.FoldersScanned++
                if ($isReparse) {
                    # Reparse points (junctions/symlinks) are treated as leaves to avoid infinite loops
                    $childNode = New-DsaNode -Name $entry.Name -FullPath $entry.FullName -IsDirectory $true -LastWriteTime $entry.LastWriteTime
                    $childNode.Parent = $node
                } else {
                    $childNode = Measure-DsaDirectory -Path $entry.FullName -ProgressState $ProgressState -CancelFlagRef $CancelFlagRef -ParentNode $node
                }
                $node.Children.Add($childNode) | Out-Null
                $node.Size += $childNode.Size
                $node.FileCount += $childNode.FileCount
                $node.FolderCount += ($childNode.FolderCount + 1)
            } else {
                $ProgressState.FilesScanned++
                $fileNode = New-DsaNode -Name $entry.Name -FullPath $entry.FullName -IsDirectory $false -Size $entry.Length -LastWriteTime $entry.LastWriteTime
                $fileNode.Parent = $node
                $node.Children.Add($fileNode) | Out-Null
                $node.Size += $entry.Length
                $node.FileCount++
            }
        }
    } catch {
        $ProgressState.AccessDenied++
    }

    return $node
}

# ============================================================================
# NTFS MFT fast path
# ============================================================================

function Read-DsaBootSector {
    param([IntPtr]$Handle)

    $raw = [Dsa.NativeMethods]::ReadAligned($Handle, 0, 512)
    $bytesPerSector = [BitConverter]::ToUInt16($raw, 0x0B)
    $sectorsPerCluster = $raw[0x0D]
    $mftStartLcn = [BitConverter]::ToInt64($raw, 0x30)
    # PowerShell's [sbyte] cast is checked and throws for values >= 128, so reinterpret manually
    $recordSizeByte = $raw[0x40]
    $clustersPerRecordRaw = if ($recordSizeByte -gt 127) { $recordSizeByte - 256 } else { $recordSizeByte }
    $bytesPerCluster = $bytesPerSector * $sectorsPerCluster

    # A negative value here means "record size = 2^abs(n) bytes" rather than a cluster count
    $fileRecordSize = if ($clustersPerRecordRaw -gt 0) {
        $clustersPerRecordRaw * $bytesPerCluster
    } else {
        [Math]::Pow(2, -$clustersPerRecordRaw)
    }

    [pscustomobject]@{
        BytesPerSector  = $bytesPerSector
        BytesPerCluster = $bytesPerCluster
        MftStartLcn     = $mftStartLcn
        FileRecordSize  = [int]$fileRecordSize
    }
}

function Get-DsaDataRuns {
    # Decodes an NTFS data-run list into (LCN, cluster-count, sparse?) tuples.
    param([byte[]]$Bytes, [int]$StartOffset)

    $runs = [System.Collections.Generic.List[object]]::new()
    $pos = $StartOffset
    $lcn = 0L

    while ($pos -lt $Bytes.Length) {
        $header = $Bytes[$pos]
        if ($header -eq 0) { break }
        $lengthSize = $header -band 0x0F
        $offsetSize = ($header -shr 4) -band 0x0F
        $pos++

        $runLength = 0L
        for ($i = 0; $i -lt $lengthSize; $i++) { $runLength = $runLength -bor ([long]$Bytes[$pos + $i] -shl (8 * $i)) }
        $pos += $lengthSize

        if ($offsetSize -eq 0) {
            $runs.Add([pscustomobject]@{ Lcn = 0; Clusters = $runLength; Sparse = $true }) | Out-Null
            continue
        }

        $raw = 0L
        for ($i = 0; $i -lt $offsetSize; $i++) { $raw = $raw -bor ([long]$Bytes[$pos + $i] -shl (8 * $i)) }
        if (($Bytes[$pos + $offsetSize - 1] -band 0x80) -ne 0) {
            $raw = $raw -bor (-1L -shl (8 * $offsetSize))
        }
        $pos += $offsetSize
        $lcn += $raw

        $runs.Add([pscustomobject]@{ Lcn = $lcn; Clusters = $runLength; Sparse = $false }) | Out-Null
    }

    return $runs
}

function Find-DsaAttributeOffset {
    param([byte[]]$Record, [uint32]$AttributeType)

    $attrOffset = [BitConverter]::ToUInt16($Record, 0x14)
    while ($attrOffset -lt $Record.Length - 4) {
        $type = [BitConverter]::ToUInt32($Record, $attrOffset)
        if ($type -eq 0xFFFFFFFF) { break }
        $len = [BitConverter]::ToUInt32($Record, $attrOffset + 4)
        if ($len -eq 0) { break }
        if ($type -eq $AttributeType -and $Record[$attrOffset + 9] -eq 0) {
            return $attrOffset
        }
        $attrOffset += $len
    }
    return $null
}

# ============================================================================
# Lazy node materialization for MFT-backed trees
#
# Dsa.MftParser.BuildHierarchy computes every directory's aggregate size
# natively, but the tree of PowerShell node objects the UI actually interacts
# with (TreeViewItem back-references, Parent chains for breadcrumbs, etc.) is
# NOT built eagerly from that — creating one PSCustomObject per MFT record
# (~940K+ on a real drive) was the dominant remaining cost even after the
# parsing loop itself was compiled, easily over a minute on its own. Instead,
# a node wrapper is only ever materialized for a record the UI is actually
# about to display, cached per-parser (via PsNodeCache) so the same record
# always resolves to the same object no matter which code path reaches it
# first (tree-view expansion, a breadcrumb click, a Top Largest Files result).
# ============================================================================

# A file can legitimately appear under more than one parent (hard links — see the
# Dsa.MftFileLink comment above), so a node's identity for caching purposes is the
# (parent record, record) pair, not the record number alone: the same file might need
# two distinct node objects, one per linked location, each with the right Name/Parent
# for that location. The cache key is a simple "parentRecord|recordNumber" string.

function New-DsaMftRootNode {
    # The volume root (record 5) is constructed directly rather than through
    # New-DsaLazyMftNode below: it has no real parent, and its on-disk name (usually
    # "." or empty) is meaningless for display, so the caller supplies the name to show
    # (e.g. "C:\").
    param($Parser, [long]$RecordNumber, [string]$Name)

    $info = $null
    if (-not $Parser.Records.TryGetValue($RecordNumber, [ref]$info)) { return $null }

    $lastWrite = $null
    if ($info.ModifiedTicks -gt 0) { try { $lastWrite = [DateTime]::FromFileTimeUtc($info.ModifiedTicks) } catch { $lastWrite = $null } }

    $node = New-DsaNode -Name $Name -IsDirectory $true -Size $info.Size -LastWriteTime $lastWrite
    $node.FullPath = $Name
    $node.FileCount = $info.FileCount
    $node.FolderCount = $info.FolderCount
    $node.MftParser = $Parser
    $node.MftRecordNumber = $RecordNumber

    $Parser.PsNodeCache["-1|$RecordNumber"] = $node
    return $node
}

function New-DsaLazyMftNode {
    param($Parser, [long]$RecordNumber, $ParentNode)

    $parentRecNum = $ParentNode.MftRecordNumber
    $cacheKey = "$parentRecNum|$RecordNumber"

    $cached = $null
    if ($Parser.PsNodeCache.TryGetValue($cacheKey, [ref]$cached)) { return $cached }

    $info = $null
    if (-not $Parser.Records.TryGetValue($RecordNumber, [ref]$info) -or $info.Links.Count -eq 0) { return $null }

    $link = $null
    foreach ($l in $info.Links) { if ($l.ParentRecordNumber -eq $parentRecNum) { $link = $l; break } }
    if (-not $link) { $link = $info.Links[0] }   # shouldn't normally happen; ChildrenByParent only lists valid pairs

    $lastWrite = $null
    if ($info.ModifiedTicks -gt 0) { try { $lastWrite = [DateTime]::FromFileTimeUtc($info.ModifiedTicks) } catch { $lastWrite = $null } }

    $node = New-DsaNode -Name $link.Name -IsDirectory $info.IsDirectory -Size $info.Size -LastWriteTime $lastWrite
    $node.Parent = $ParentNode
    $node.FullPath = Join-Path $ParentNode.FullPath $link.Name
    $node.FileCount = $info.FileCount
    $node.FolderCount = $info.FolderCount
    $node.MftParser = $Parser
    $node.MftRecordNumber = $RecordNumber

    $Parser.PsNodeCache[$cacheKey] = $node
    return $node
}

function Get-DsaAncestorChainNode {
    # Resolves the lazy node for a record reached directly (e.g. a Top-N result),
    # materializing every ancestor down from the volume root along the way so
    # .Parent/.FullPath are correct. Always follows each record's first recorded link
    # when walking up — for a multi-linked file this picks one representative location,
    # which is enough to navigate to and act on it.
    param($Parser, [long]$RecordNumber)

    if ($RecordNumber -eq 5) {
        # The volume root's own record — its self-referential parent link would
        # otherwise make the chain walk below materialize a bogus "child of itself"
        # node named after its on-disk ("." ) name. Just hand back the real root.
        $rootNode = $null
        $Parser.PsNodeCache.TryGetValue('-1|5', [ref]$rootNode) | Out-Null
        return $rootNode
    }

    $chain = [System.Collections.Generic.List[long]]::new()
    $current = $RecordNumber
    while ($true) {
        $chain.Insert(0, $current)
        $info = $null
        if (-not $Parser.Records.TryGetValue($current, [ref]$info) -or $info.Links.Count -eq 0) { return $null }
        $parentRecNum = $info.Links[0].ParentRecordNumber
        if ($parentRecNum -eq 5) { $chain.Insert(0, 5); break }
        if ($parentRecNum -lt 0) { return $null }
        $current = $parentRecNum
    }

    $result = $null
    if (-not $Parser.PsNodeCache.TryGetValue("-1|5", [ref]$result)) { return $null }   # root not yet materialized

    for ($i = 1; $i -lt $chain.Count; $i++) {
        $result = New-DsaLazyMftNode -Parser $Parser -RecordNumber $chain[$i] -ParentNode $result
        if (-not $result) { return $null }
    }
    return $result
}

function Get-DsaNodeChildren {
    # Unified children accessor: enumeration-scanned nodes already have .Children fully
    # populated; MFT-backed nodes materialize (and cache) their direct children on
    # first access instead of the whole subtree, so viewing one folder never touches
    # more than that folder's own immediate contents.
    param($Node)

    if ($null -ne $Node._MaterializedChildren) {
        return $Node._MaterializedChildren
    }

    if ($Node.MftParser) {
        $result = [System.Collections.Generic.List[object]]::new()
        $childIds = $null
        if ($Node.MftParser.ChildrenByParent.TryGetValue($Node.MftRecordNumber, [ref]$childIds)) {
            foreach ($id in $childIds) {
                $child = New-DsaLazyMftNode -Parser $Node.MftParser -RecordNumber $id -ParentNode $Node
                if ($child) { $result.Add($child) | Out-Null }
            }
        }
        $Node._MaterializedChildren = $result
        return $result
    }

    return $Node.Children
}

function Remove-DsaChildFromParent {
    param($Parent, $Child)
    if ($Parent._MaterializedChildren) {
        $Parent._MaterializedChildren.Remove($Child) | Out-Null
    } else {
        $Parent.Children.Remove($Child) | Out-Null
    }
}

function Get-DsaTopItemsForNode {
    # Routes "Top Largest Files/Folders" to the fast C#-side GetTopItems for MFT-backed
    # drives (a flat sort over the already-built Records dictionary, no tree walk),
    # aggregates that same fast path across every drive for the "This PC" synthetic
    # root, and falls back to the plain PowerShell tree-flatten for enumeration-scanned
    # trees.
    param($Node, [bool]$FoldersOnly, [int]$Top = 200)

    if ($Node.MftParser) {
        $rawItems = $Node.MftParser.GetTopItems($FoldersOnly, $Top)
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($info in $rawItems) {
            $resolved = Get-DsaAncestorChainNode -Parser $Node.MftParser -RecordNumber $info.RecordNumber
            if ($resolved) { $result.Add($resolved) | Out-Null }
        }
        return $result
    }

    if ($Node.IsThisPcRoot) {
        $combined = [System.Collections.Generic.List[object]]::new()
        foreach ($drive in $Node.Children) {
            (Get-DsaTopItemsForNode -Node $drive -FoldersOnly $FoldersOnly -Top $Top) | ForEach-Object { $combined.Add($_) | Out-Null }
        }
        return $combined | Sort-Object -Property Size -Descending | Select-Object -First $Top
    }

    return Get-DsaTopItems -Root $Node -FoldersOnly:$FoldersOnly -Top $Top
}

function Update-DsaAggregateAcrossDrives {
    param($Node)
    $totalSize = 0L; $totalFiles = 0; $totalFolders = 0
    foreach ($child in $Node.Children) {
        $totalSize += $child.Size
        $totalFiles += $child.FileCount
        $totalFolders += (1 + $child.FolderCount)
    }
    $Node.Size = $totalSize
    $Node.FileCount = $totalFiles
    $Node.FolderCount = $totalFolders
    $Node.FullPath = 'This PC'
}

function Read-DsaMftTree {
    param(
        [string]$DriveLetter,
        [hashtable]$ProgressState,
        [ref]$CancelFlagRef
    )

    $handle = [IntPtr]::Zero
    try {
        $volumePath = "\\.\$($DriveLetter):"
        $GENERIC_READ = [uint32]2147483648   # 0x80000000 — written in decimal because PowerShell parses that hex literal as a negative Int32
        $FILE_SHARE_READ = 1; $FILE_SHARE_WRITE = 2
        $OPEN_EXISTING = 3
        $FILE_FLAG_NO_BUFFERING = [uint32]536870912   # 0x20000000 — direct/unbuffered I/O; see ReadAligned above for why

        $handle = [Dsa.NativeMethods]::CreateFile($volumePath, $GENERIC_READ, ($FILE_SHARE_READ -bor $FILE_SHARE_WRITE), [IntPtr]::Zero, $OPEN_EXISTING, $FILE_FLAG_NO_BUFFERING, [IntPtr]::Zero)
        if ($handle -eq [IntPtr]::Zero -or $handle.ToInt64() -eq -1) {
            throw "Unable to open volume $volumePath (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }

        $boot = Read-DsaBootSector -Handle $handle
        $mftByteOffset = $boot.MftStartLcn * $boot.BytesPerCluster

        $mftRecord0 = [Dsa.NativeMethods]::ReadAligned($handle, $mftByteOffset, $boot.FileRecordSize)
        [Dsa.MftParser]::RepairFixup($mftRecord0, $boot.BytesPerSector)

        $dataAttrOffset = Find-DsaAttributeOffset -Record $mftRecord0 -AttributeType 0x80
        if (-not $dataAttrOffset) { throw 'Could not locate $MFT $DATA attribute' }
        if ($mftRecord0[$dataAttrOffset + 8] -eq 0) { throw 'Unexpected resident $MFT $DATA attribute' }

        $dataRunsRelOffset = [BitConverter]::ToUInt16($mftRecord0, $dataAttrOffset + 0x20)
        $dataRuns = Get-DsaDataRuns -Bytes $mftRecord0 -StartOffset ($dataAttrOffset + $dataRunsRelOffset)

        # The hot per-record parsing loop lives in Dsa.MftParser (compiled C#, see the
        # Add-Type block above) — PowerShell only pays interpreter overhead once per
        # ~4MB chunk (one ParseChunk call) instead of once per MFT record.
        $parser = New-Object Dsa.MftParser
        $recordNumber = 0L
        $recordSize = $boot.FileRecordSize
        $chunkRecordCount = [Math]::Max(1, [int]([Math]::Floor(4MB / $recordSize)))
        $chunkBytesMax = $chunkRecordCount * $recordSize

        foreach ($run in $dataRuns) {
            if ($CancelFlagRef.Value) { break }

            if ($run.Sparse) {
                $recordNumber += [long](($run.Clusters * $boot.BytesPerCluster) / $recordSize)
                continue
            }

            $runByteOffset = $run.Lcn * $boot.BytesPerCluster
            $runByteLength = $run.Clusters * $boot.BytesPerCluster
            $consumed = 0L

            while ($consumed -lt $runByteLength) {
                if ($CancelFlagRef.Value) { break }

                $thisChunkBytes = [Math]::Min($chunkBytesMax, $runByteLength - $consumed)
                $recordsInChunk = [int]([Math]::Floor($thisChunkBytes / $recordSize))
                if ($recordsInChunk -lt 1) { break }

                $buffer = [Dsa.NativeMethods]::ReadAligned($handle, ($runByteOffset + $consumed), ($recordsInChunk * $recordSize))
                $parser.ParseChunk($buffer, $recordsInChunk, $recordSize, $boot.BytesPerSector, $recordNumber)

                $ProgressState.FilesScanned = $parser.FilesFound
                $ProgressState.FoldersScanned = $parser.FoldersFound

                $recordNumber += $recordsInChunk
                $consumed += ($recordsInChunk * $recordSize)
            }
        }

        # BuildHierarchy computes every directory's aggregate Size/FileCount/FolderCount
        # natively; PowerShell only ever materializes a node object for a record the UI
        # is actually about to show (see "Lazy node materialization" below).
        $parser | Add-Member -NotePropertyName PsNodeCache -NotePropertyValue ([System.Collections.Generic.Dictionary[string, object]]::new()) -Force
        $parser.BuildHierarchy(5)

        $root = New-DsaMftRootNode -Parser $parser -RecordNumber 5 -Name "$($DriveLetter):\"
        if (-not $root) { throw 'Volume root MFT record (5) not found' }

        return $root
    }
    finally {
        if ($handle -ne [IntPtr]::Zero -and $handle.ToInt64() -ne -1) {
            [Dsa.NativeMethods]::CloseHandle($handle) | Out-Null
        }
    }
}

# ============================================================================
# Filesystem-adaptive dispatcher
# ============================================================================

function Find-DsaNodeByPath {
    param($Root, [string]$Path)

    $rootPath = $Root.FullPath.TrimEnd('\')
    $target = $Path.TrimEnd('\')
    if ($target.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) { return $Root }
    if ($target.Length -le $rootPath.Length) { return $Root }

    $relative = $target.Substring($rootPath.Length).Trim('\')
    if ([string]::IsNullOrEmpty($relative)) { return $Root }

    $current = $Root
    foreach ($seg in ($relative -split '\\')) {
        $next = (Get-DsaNodeChildren -Node $current) | Where-Object { $_.IsDirectory -and $_.Name -ieq $seg } | Select-Object -First 1
        if (-not $next) { return $current }
        $current = $next
    }
    return $current
}

function Get-DsaVolumeTree {
    param(
        [string]$Path,
        [hashtable]$ProgressState,
        [ref]$CancelFlagRef
    )

    $rootPath = [System.IO.Path]::GetPathRoot($Path)
    $driveLetter = $rootPath.TrimEnd('\', ':')

    $format = $null
    try { $format = ([System.IO.DriveInfo]::new($rootPath)).DriveFormat } catch { }

    if ($script:DsaNativeAvailable -and $format -eq 'NTFS' -and $driveLetter.Length -eq 1) {
        try {
            Write-Log "Attempting MFT fast scan for drive $($driveLetter):..." -Level Info
            $mftRoot = Read-DsaMftTree -DriveLetter $driveLetter -ProgressState $ProgressState -CancelFlagRef $CancelFlagRef
            if ($mftRoot) {
                Write-Log "MFT fast scan completed for drive $($driveLetter):." -Level Success
                if ($Path.TrimEnd('\') -ne "$($driveLetter):") {
                    return Find-DsaNodeByPath -Root $mftRoot -Path $Path
                }
                return $mftRoot
            }
        } catch {
            Write-Log "MFT fast path failed for drive $($driveLetter): ($($_.Exception.Message)) - falling back to standard scan." -Level Warning
        }
    }

    return Measure-DsaDirectory -Path $Path -ProgressState $ProgressState -CancelFlagRef $CancelFlagRef
}

# ============================================================================
# Squarified treemap layout (pure function, no WPF dependency)
# ============================================================================

function Get-DsaTreemapLayout {
    # The squarify inner loop tests every remaining candidate against the row being
    # built, which is inherently O(n^2)-ish for n items in one folder. That's fine in
    # principle (n is capped at 25 by Get-DsaTreemapChildren) — but this used to call
    # Get-DsaWorstRatio, which ran three Measure-Object pipelines per candidate.
    # Measure-Object's cmdlet-binding overhead, multiplied by an O(n^2) loop, was
    # costing ~1 second per folder in testing (a real, measured cost, not a one-off
    # JIT warm-up) — enough on its own to freeze the window during a treemap render.
    # Everything here is now plain scalar arithmetic with running sum/max/min tracked
    # incrementally, no cmdlet pipelines in the hot path at all.
    param([array]$Items, [double]$X, [double]$Y, [double]$Width, [double]$Height)

    $result = [System.Collections.Generic.List[object]]::new()
    if (-not $Items -or $Items.Count -eq 0 -or $Width -le 0 -or $Height -le 0) { return $result }

    $totalSize = 0.0
    foreach ($item in $Items) { $totalSize += $item.Size }
    if ($totalSize -le 0) { return $result }

    $scale = ($Width * $Height) / $totalSize
    $remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($item in ($Items | Sort-Object -Property Size -Descending)) { $remaining.Add($item) | Out-Null }

    $cx = $X; $cy = $Y; $cw = $Width; $ch = $Height

    while ($remaining.Count -gt 0) {
        $side = [Math]::Min($cw, $ch)
        if ($side -le 0) { break }
        $s2 = $side * $side

        $row = [System.Collections.Generic.List[object]]::new()
        $rowAreas = [System.Collections.Generic.List[double]]::new()
        $bestRatio = [double]::PositiveInfinity
        $rowSum = 0.0; $rowMax = 0.0; $rowMin = 0.0

        for ($i = 0; $i -lt $remaining.Count; $i++) {
            $candidateArea = $remaining[$i].Size * $scale
            $testSum = $rowSum + $candidateArea
            $testMax = if ($rowAreas.Count -eq 0 -or $candidateArea -gt $rowMax) { $candidateArea } else { $rowMax }
            $testMin = if ($rowAreas.Count -eq 0 -or $candidateArea -lt $rowMin) { $candidateArea } else { $rowMin }

            $ratio = if ($testSum -le 0 -or $testMin -le 0) {
                [double]::PositiveInfinity
            } else {
                [Math]::Max((($s2 * $testMax) / ($testSum * $testSum)), (($testSum * $testSum) / ($s2 * $testMin)))
            }

            if ($ratio -le $bestRatio) {
                $bestRatio = $ratio
                $row.Add($remaining[$i]) | Out-Null
                $rowAreas.Add($candidateArea) | Out-Null
                $rowSum = $testSum; $rowMax = $testMax; $rowMin = $testMin
            } else {
                break
            }
        }
        if ($row.Count -eq 0) {
            $row.Add($remaining[0]) | Out-Null
            $rowAreas.Add($remaining[0].Size * $scale) | Out-Null
            $rowSum = $rowAreas[0]
        }
        for ($k = 0; $k -lt $row.Count; $k++) { $remaining.RemoveAt(0) }

        $rowArea = $rowSum

        if ($cw -ge $ch) {
            $rowWidth = if ($ch -gt 0) { $rowArea / $ch } else { 0 }
            $yOffset = $cy
            for ($k = 0; $k -lt $row.Count; $k++) {
                $itemHeight = if ($rowWidth -gt 0) { $rowAreas[$k] / $rowWidth } else { 0 }
                $result.Add([pscustomobject]@{ Node = $row[$k].Node; X = $cx; Y = $yOffset; Width = $rowWidth; Height = $itemHeight }) | Out-Null
                $yOffset += $itemHeight
            }
            $cx += $rowWidth; $cw -= $rowWidth
        } else {
            $rowHeight = if ($cw -gt 0) { $rowArea / $cw } else { 0 }
            $xOffset = $cx
            for ($k = 0; $k -lt $row.Count; $k++) {
                $itemWidth = if ($rowHeight -gt 0) { $rowAreas[$k] / $rowHeight } else { 0 }
                $result.Add([pscustomobject]@{ Node = $row[$k].Node; X = $xOffset; Y = $cy; Width = $itemWidth; Height = $rowHeight }) | Out-Null
                $xOffset += $itemWidth
            }
            $cy += $rowHeight; $ch -= $rowHeight
        }
    }

    return $result
}

# ============================================================================
# Top-N flatten helpers ("where can I free up space" global report modes)
# ============================================================================

function Get-DsaFlattenedItems {
    param($Node, [bool]$FoldersOnly, [System.Collections.Generic.List[object]]$Accumulator)
    foreach ($child in (Get-DsaNodeChildren -Node $Node)) {
        if ($child.IsDirectory) {
            if ($FoldersOnly) { $Accumulator.Add($child) | Out-Null }
            Get-DsaFlattenedItems -Node $child -FoldersOnly $FoldersOnly -Accumulator $Accumulator
        } elseif (-not $FoldersOnly) {
            $Accumulator.Add($child) | Out-Null
        }
    }
}

function Get-DsaTopItems {
    param($Root, [bool]$FoldersOnly, [int]$Top = 200)
    $all = [System.Collections.Generic.List[object]]::new()
    Get-DsaFlattenedItems -Node $Root -FoldersOnly $FoldersOnly -Accumulator $all
    return $all | Sort-Object -Property Size -Descending | Select-Object -First $Top
}

# ============================================================================
# View-update functions
#
# Everything below is defined at module (top-level) scope on purpose, even
# though it's only ever used from Get-StorageManagementUI's controls: WPF
# event handlers fire long after Get-StorageManagementUI has returned, and a
# PowerShell scriptblock only keeps access to an enclosing function's LOCAL
# scope via .GetNewClosure(). All state these functions need lives on
# $Global:SyncHash instead, so they behave as true global functions (same
# pattern Write-Log / Start-SoftwareStatusRefresh use elsewhere in this repo)
# and every event handler can call them directly with no closure required.
# ============================================================================

function Get-DsaRowsForNode {
    param($Node, [string]$Mode)

    $rows = [System.Collections.Generic.List[object]]::new()
    $items = if ($Mode -eq 'TopFiles') {
        Get-DsaTopItemsForNode -Node $Node -FoldersOnly:$false -Top 200
    } elseif ($Mode -eq 'TopFolders') {
        Get-DsaTopItemsForNode -Node $Node -FoldersOnly:$true -Top 200
    } else {
        Get-DsaNodeChildren -Node $Node
    }

    $parentSize = if ($Node.Size -gt 0) { $Node.Size } else { 1 }
    foreach ($child in $items) {
        $pct = if ($Mode -eq 'Browse') { ($child.Size / $parentSize) * 100 } else { 0 }
        $displayName = if ($Mode -eq 'Browse') { $child.Name } else { $child.FullPath }
        # [char] only holds one UTF-16 code unit (0-65535); these emoji are outside the
        # Basic Multilingual Plane and need a real surrogate pair via ConvertFromUtf32.
        $glyph = if ($child.IsDirectory) { [char]::ConvertFromUtf32(0x1F4C1) } else { [char]::ConvertFromUtf32(0x1F4C4) }
        $rows.Add([pscustomobject]@{
            Node            = $child
            DisplayName     = "$glyph $displayName"
            SizeDisplay     = Format-DsaSize $child.Size
            SizeBytes       = $child.Size
            PercentDisplay  = if ($Mode -eq 'Browse') { Get-DsaPercentBarText -Percent $pct } else { '' }
            FileCount       = if ($child.IsDirectory) { $child.FileCount } else { 0 }
            FolderCount     = if ($child.IsDirectory) { $child.FolderCount } else { 0 }
            ModifiedDisplay = if ($child.LastWriteTime) { $child.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
        }) | Out-Null
    }
    return $rows
}

function Update-DsaListView {
    param($Node)
    $mode = $Global:SyncHash.DsaListMode
    $rows = Get-DsaRowsForNode -Node $Node -Mode $mode
    $sorted = if ($Global:SyncHash.DsaSortAscending) {
        $rows | Sort-Object -Property $Global:SyncHash.DsaSortColumn
    } else {
        $rows | Sort-Object -Property $Global:SyncHash.DsaSortColumn -Descending
    }
    $Global:SyncHash.DsaListView.ItemsSource = @($sorted)
}

function Update-DsaBreadcrumb {
    param($Node)
    $panel = $Global:SyncHash.DsaBreadcrumbPanel
    $panel.Children.Clear()
    $chain = [System.Collections.Generic.List[object]]::new()
    $n = $Node
    while ($n) { $chain.Insert(0, $n); $n = $n.Parent }

    for ($i = 0; $i -lt $chain.Count; $i++) {
        $segNode = $chain[$i]
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $segNode.Name
        $btn.Tag = $segNode
        $btn.Padding = [System.Windows.Thickness]::new(4, 1, 4, 1)
        $btn.Margin = [System.Windows.Thickness]::new(0, 0, 2, 0)
        $btn.Background = [System.Windows.Media.Brushes]::Transparent
        $btn.Foreground = New-DsaBrush (Get-ToolkitAccent)
        $btn.BorderThickness = [System.Windows.Thickness]::new(0)
        $btn.Cursor = 'Hand'
        $btn.Add_Click({ param($s, $e) Set-DsaCurrentNode -Node $s.Tag })
        $panel.Children.Add($btn) | Out-Null
        if ($i -lt $chain.Count - 1) {
            $sep = New-Object System.Windows.Controls.TextBlock
            $sep.Text = ' > '
            $sep.Foreground = New-DsaBrush '#6C7086'
            $sep.VerticalAlignment = 'Center'
            $panel.Children.Add($sep) | Out-Null
        }
    }
}

function Get-DsaTreemapChildren {
    # A folder with hundreds of files only ever contributes a handful of visually
    # meaningful rectangles to a treemap; materializing every single child just to
    # discover that was the other big cost behind a slow full-drive treemap render.
    # For MFT-backed folders this stays entirely in C# (sizes are looked up straight
    # from the Records dictionary) until only the top MaxItems survive.
    param($Node, [int]$MaxItems = 60)

    if ($Node.MftParser) {
        $topInfos = $Node.MftParser.GetTopChildren($Node.MftRecordNumber, $MaxItems)
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($info in $topInfos) {
            $child = New-DsaLazyMftNode -Parser $Node.MftParser -RecordNumber $info.RecordNumber -ParentNode $Node
            if ($child) { $result.Add($child) | Out-Null }
        }
        return $result
    }

    return (Get-DsaNodeChildren -Node $Node) | Where-Object { $_.Size -gt 0 } | Sort-Object -Property Size -Descending | Select-Object -First $MaxItems
}

function Invoke-DsaWpfWarmup {
    # The very first Shape (Rectangle) created in a process, and the first time
    # mouse-event handlers get attached to one, pays a one-time JIT/type-init cost —
    # measured at 300-650ms in testing, confirmed to be entirely per-process (identical
    # cost hit regardless of which data/rectangles triggered it, and gone on every
    # subsequent call in the same process). Nothing else in this toolkit uses
    # Canvas/Shapes, so the treemap would otherwise be the first thing to pay it —
    # right after a scan completes, exactly when a pause reads as "frozen". Paying it
    # here instead, once, when the module UI is first built, moves that cost to a
    # moment where a brief pause is unremarkable.
    try {
        $c = New-Object System.Windows.Controls.Canvas
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Width = 1; $r.Height = 1
        $r.Fill = New-DsaBrush '#000000'
        $r.Stroke = New-DsaBrush '#000000'
        $c.Children.Add($r) | Out-Null
        $r.Add_MouseLeftButtonUp({ param($sender, $e) })
        $r.Add_MouseRightButtonUp({ param($sender, $e) })
        $c.Children.Remove($r)
    } catch { }
}

function Initialize-DsaTreemapCache {
    # Pre-materializes and lays out (but does not draw) the same subtree the initial
    # treemap render will need, run on the background scan thread right after the scan
    # itself finishes — while the user is still looking at "Scanning...", not the UI
    # thread. Testing showed the first tick of a real treemap render could take over a
    # second, and per-tick item/time caps couldn't fix that: a single folder-visit
    # (the volume root in particular) was itself the atomic unit costing that much, so
    # nothing on the UI thread could interrupt mid-visit. That cost turned out to be
    # real computation (node materialization), not one-off JIT warm-up, so the actual
    # fix is doing it ahead of time on a thread where it's free, not chunking it
    # differently on the thread where it isn't. Layout itself isn't cached (cheap pure
    # math, fine to recompute), only the node materialization that feeds it.
    param($Node, [double]$Width = 800, [double]$Height = 300)

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Node = $Node; Width = $Width; Height = $Height; Depth = 0 })
    $budget = 250

    while ($queue.Count -gt 0 -and $budget -gt 0) {
        $work = $queue.Dequeue()
        if ($work.Width -lt 2 -or $work.Height -lt 2 -or $work.Depth -gt 6) { continue }

        $items = @()
        foreach ($child in (Get-DsaTreemapChildren -Node $work.Node -MaxItems 25)) {
            $items += [pscustomobject]@{ Node = $child; Size = $child.Size }
        }
        if ($items.Count -eq 0) { continue }

        $layout = Get-DsaTreemapLayout -Items $items -X 0 -Y 0 -Width $work.Width -Height $work.Height
        foreach ($rect in $layout) {
            if ($budget -le 0) { break }
            $budget--
            if ($rect.Node.IsDirectory -and $rect.Width -ge 24 -and $rect.Height -ge 24) {
                $queue.Enqueue([pscustomobject]@{ Node = $rect.Node; Width = ($rect.Width - 2); Height = ($rect.Height - 14); Depth = ($work.Depth + 1) })
            }
        }
    }
}

function Invoke-DsaTreemapNode {
    # Draws one node's children as treemap rectangles. Subfolders big enough to
    # subdivide further are ENQUEUED rather than recursed into immediately — see
    # Update-DsaTreemap/Invoke-DsaTreemapTick below for why: building the whole thing
    # in one call, even budget-capped, was slow enough (well over a second for the
    # whole-C:-drive root) to freeze the window solid for that whole time, since WPF
    # UI work only ever runs on the UI thread and nothing else can happen while it's
    # busy. $State (a shared hashtable, same pattern as $ProgressState elsewhere in
    # this file) tracks the remaining rectangle budget across every call in a render.
    param($Canvas, $Node, [double]$X, [double]$Y, [double]$Width, [double]$Height, [int]$Depth, $Queue, [hashtable]$State)

    if ($Width -lt 2 -or $Height -lt 2 -or $Depth -gt 6 -or $State.Budget -le 0) { return }

    $items = @()
    foreach ($child in (Get-DsaTreemapChildren -Node $Node -MaxItems 25)) {
        $items += [pscustomobject]@{ Node = $child; Size = $child.Size }
    }
    if ($items.Count -eq 0) { return }

    $layout = Get-DsaTreemapLayout -Items $items -X $X -Y $Y -Width $Width -Height $Height

    foreach ($rect in $layout) {
        if ($State.Budget -le 0) { break }
        $State.Budget--

        $color = Get-DsaItemColor -Node $rect.Node -DepthIndex $Depth
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Width = [Math]::Max(0, $rect.Width - 1)
        $r.Height = [Math]::Max(0, $rect.Height - 1)
        $r.Fill = New-DsaBrush $color
        $r.Stroke = New-DsaBrush '#FF1E1E2E'
        $r.StrokeThickness = 1
        $r.Tag = $rect.Node
        $r.ToolTip = "$($rect.Node.Name)`n$(Format-DsaSize $rect.Node.Size)"
        $r.ContextMenu = $Global:SyncHash.DsaContextMenu
        $r.Cursor = 'Hand'
        [System.Windows.Controls.Canvas]::SetLeft($r, $rect.X)
        [System.Windows.Controls.Canvas]::SetTop($r, $rect.Y)
        $Canvas.Children.Add($r) | Out-Null

        $r.Add_MouseLeftButtonUp({
            param($sender, $e)
            $clickedNode = $sender.Tag
            if ($clickedNode.IsDirectory) { Set-DsaCurrentNode -Node $clickedNode }
            else { Open-DsaContainingFolder -Node $clickedNode }
        })
        $r.Add_MouseRightButtonUp({ param($sender, $e) $Global:SyncHash.DsaContextMenuTargetNode = $sender.Tag })

        $showLabel = ($rect.Width -gt 40 -and $rect.Height -gt 16)
        if ($showLabel) {
            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = $rect.Node.Name
            $label.Foreground = [System.Windows.Media.Brushes]::White
            $label.FontSize = 10
            $label.IsHitTestVisible = $false
            $label.Width = [Math]::Max(0, $rect.Width - 4)
            $label.TextTrimming = 'CharacterEllipsis'
            [System.Windows.Controls.Canvas]::SetLeft($label, $rect.X + 2)
            [System.Windows.Controls.Canvas]::SetTop($label, $rect.Y + 1)
            $Canvas.Children.Add($label) | Out-Null
        }

        if ($rect.Node.IsDirectory -and $rect.Width -ge 24 -and $rect.Height -ge 24) {
            $headerH = if ($showLabel) { 13 } else { 0 }
            $innerY = $rect.Y + $headerH
            $innerH = $rect.Height - $headerH - 1
            if ($innerH -gt 2) {
                $Queue.Enqueue([pscustomobject]@{
                    Node = $rect.Node; X = ($rect.X + 1); Y = $innerY
                    Width = ($rect.Width - 2); Height = $innerH; Depth = ($Depth + 1)
                })
            }
        }
    }
}

function Invoke-DsaTreemapTick {
    # Runs on the UI thread via DispatcherTimer, but only processes a bounded slice of
    # queued work per tick and then returns control — the render finishes over many
    # ticks instead of one long call, so the window keeps repainting and responding
    # to input throughout, even for a treemap that takes a second or more overall.
    #
    # The slice is bounded BOTH by elapsed time (~40ms) AND by a hard item-count cap:
    # the time check only runs BETWEEN whole folder-visits, so it can't interrupt one
    # already in progress — and testing found a single folder-visit can itself take
    # 700ms (the volume root's first materialization pass in particular; likely
    # one-time JIT/cache warm-up cost). Without the separate item cap, a tick landing
    # on an expensive folder would blow straight through the time budget before it
    # ever got a chance to check the clock.
    $render = $Global:SyncHash.DsaTreemapRender
    if (-not $render) { return }

    $tickSw = [System.Diagnostics.Stopwatch]::StartNew()
    $itemsThisTick = 0
    while ($render.Queue.Count -gt 0 -and $render.State.Budget -gt 0 -and $itemsThisTick -lt 2 -and $tickSw.Elapsed.TotalMilliseconds -lt 40) {
        $work = $render.Queue.Dequeue()
        Invoke-DsaTreemapNode -Canvas $render.Canvas -Node $work.Node -X $work.X -Y $work.Y -Width $work.Width -Height $work.Height -Depth $work.Depth -Queue $render.Queue -State $render.State
        $itemsThisTick++
    }

    if ($render.Queue.Count -eq 0 -or $render.State.Budget -le 0) {
        $render.Timer.Stop()
        $Global:SyncHash.DsaTreemapRender = $null
    }
}

function Update-DsaTreemap {
    param($Node)
    $canvas = $Global:SyncHash.DsaTreemapCanvas

    # Cancel any render still in flight for a previously-selected node before starting
    # a new one (e.g. the user navigated again before the last treemap finished).
    if ($Global:SyncHash.DsaTreemapRender) {
        $Global:SyncHash.DsaTreemapRender.Timer.Stop()
        $Global:SyncHash.DsaTreemapRender = $null
    }

    $canvas.Children.Clear()
    $w = $canvas.ActualWidth
    $h = $canvas.ActualHeight
    if ($w -lt 4 -or $h -lt 4) { return }

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Node = $Node; X = 0; Y = 0; Width = $w; Height = $h; Depth = 0 })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(1)
    $timer.Add_Tick({ Invoke-DsaTreemapTick })

    $Global:SyncHash.DsaTreemapRender = [pscustomobject]@{
        Queue  = $queue
        State  = @{ Budget = 250 }
        Canvas = $canvas
        Timer  = $timer
    }
    $timer.Start()
}

function Expand-DsaTreeViewItemChildren {
    param($Item, $Node)

    $Item.Items.Clear()
    $dirChildren = (Get-DsaNodeChildren -Node $Node) | Where-Object { $_.IsDirectory } | Sort-Object -Property Size -Descending
    foreach ($child in $dirChildren) {
        $childItem = New-DsaTreeViewItem -Node $child
        $Item.Items.Add($childItem) | Out-Null
    }
}

function New-DsaTreeViewItem {
    param($Node)

    $item = New-Object System.Windows.Controls.TreeViewItem
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Orientation = 'Horizontal'
    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Text = "$([char]::ConvertFromUtf32(0x1F4C1)) "
    $stack.Children.Add($icon) | Out-Null
    $nameText = New-Object System.Windows.Controls.TextBlock
    $nameText.Text = "$($Node.Name)  ($(Format-DsaSize $Node.Size))"
    $nameText.Foreground = New-DsaBrush '#CDD6F4'
    $stack.Children.Add($nameText) | Out-Null
    $item.Header = $stack
    $item.Tag = $Node
    $Node.TreeViewItem = $item

    $hasSubfolders = if ($Node.MftParser) {
        $Node.MftParser.HasDirectoryChild($Node.MftRecordNumber)
    } else {
        [bool]((Get-DsaNodeChildren -Node $Node) | Where-Object { $_.IsDirectory } | Select-Object -First 1)
    }
    if ($hasSubfolders) {
        $placeholder = New-Object System.Windows.Controls.TreeViewItem
        $placeholder.Header = '...'
        $item.Items.Add($placeholder) | Out-Null
        $item.Add_Expanded({
            param($sender, $e)
            if ($sender -ne $e.OriginalSource) { return }
            if ($sender.Items.Count -eq 1 -and $sender.Items[0].Header -eq '...') {
                Expand-DsaTreeViewItemChildren -Item $sender -Node $sender.Tag
            }
        })
    }

    $item.Add_Selected({
        param($sender, $e)
        if ($sender -ne $e.OriginalSource) { return }
        Set-DsaCurrentNode -Node $sender.Tag -SkipTreeSync
    })

    return $item
}

function Select-DsaTreeViewItemForNode {
    param($Node)

    if ($Node.TreeViewItem) {
        $Node.TreeViewItem.IsSelected = $true
        $Node.TreeViewItem.BringIntoView()
        return
    }

    $ancestors = [System.Collections.Generic.List[object]]::new()
    $n = $Node
    while ($n -and -not $n.TreeViewItem) { $ancestors.Insert(0, $n); $n = $n.Parent }
    if (-not $n) { return }

    foreach ($ancestor in $ancestors) {
        $parentItem = $n.TreeViewItem
        if (-not $parentItem) { return }
        if ($parentItem.Items.Count -eq 1 -and $parentItem.Items[0].Header -eq '...') {
            Expand-DsaTreeViewItemChildren -Item $parentItem -Node $n
        }
        $parentItem.IsExpanded = $true
        $n = $ancestor
    }
    if ($Node.TreeViewItem) {
        $Node.TreeViewItem.IsSelected = $true
        $Node.TreeViewItem.BringIntoView()
    }
}

function Set-DsaCurrentNode {
    param($Node, [switch]$SkipTreeSync)
    $Global:SyncHash.DsaCurrentNode = $Node
    Update-DsaBreadcrumb -Node $Node
    Update-DsaListView -Node $Node
    Update-DsaTreemap -Node $Node
    if (-not $SkipTreeSync) { Select-DsaTreeViewItemForNode -Node $Node }
}

function Open-DsaContainingFolder {
    param($Node)
    if ($Node.FullPath -and (Test-Path $Node.FullPath)) {
        Start-Process explorer.exe -ArgumentList "/select,`"$($Node.FullPath)`""
    }
}

function Start-DsaScan {
    # Guards against a second scan overlapping a first — the Scan button already
    # disables itself while a scan runs, but the "Refresh" context-menu item calls
    # Start-DsaScan directly and doesn't go through that button, so it could
    # otherwise fire a second background runspace while one is still in flight.
    # Two scans racing to Dispatcher.Invoke UI updates against the same TreeView/
    # ListView isn't just visually wrong, it's how background runspaces pile up
    # (see the cleanup below) and end up contending for the UI thread.
    if ($Global:SyncHash.DsaScanInProgress) { return }
    $Global:SyncHash.DsaScanInProgress = $true

    $target = $Global:SyncHash.DsaTargetCombo.SelectedItem
    $isThisPc = $false
    $scanPaths = @()

    if ($Global:SyncHash.DsaBrowseFolderPath) {
        $scanPaths = @($Global:SyncHash.DsaBrowseFolderPath)
    } elseif ($target -eq 'This PC (all drives)') {
        $scanPaths = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.Name }
        $isThisPc = $true
    } else {
        $scanPaths = @($target)
    }

    $Global:SyncHash.DsaCancelRequested = $false
    $Global:SyncHash.DsaScanBtn.IsEnabled = $false
    $Global:SyncHash.DsaCancelBtn.Visibility = 'Visible'
    $Global:SyncHash.DsaStatusText.Text = 'Scanning...'
    $Global:SyncHash.DsaTreeView.Items.Clear()
    $Global:SyncHash.DsaListView.ItemsSource = $null
    $Global:SyncHash.DsaTreemapCanvas.Children.Clear()
    $Global:SyncHash.DsaBreadcrumbPanel.Children.Clear()
    $Global:SyncHash.DsaProgress = @{ FilesScanned = 0; FoldersScanned = 0; AccessDenied = 0 }

    # The background scan thread hands its result back by setting
    # $Global:SyncHash.DsaScanResult and nothing else — no Dispatcher.Invoke/
    # BeginInvoke call. In testing, that final cross-thread Dispatcher call
    # reliably hung (the background thread never regained control, even with
    # BeginInvoke, which is documented as non-blocking) once the full app's real
    # scan/UI state was involved, despite every simplified repro of the same
    # STA-runspace + Dispatcher pattern working fine in isolation. Rather than
    # chase that further, this sidesteps it: the UI thread already polls every
    # 300ms for progress text, so it's just as well positioned to notice a
    # finished scan and do the heavy UI update itself, entirely on the UI
    # thread — no cross-thread call in the critical path at all.
    $Global:SyncHash.DsaScanResult = $null
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
        $result = $Global:SyncHash.DsaScanResult
        if ($result) {
            $Global:SyncHash.DsaScanResult = $null
            $Global:SyncHash.DsaTimer.Stop()

            if ($Global:SyncHash.Toolkit.Session -and $result.Entry) {
                $Global:SyncHash.Toolkit.Session.ModulesRun.Add($result.Entry) | Out-Null
            }

            if ($result.Success) {
                $Global:SyncHash.DsaRootNode = $result.RootNode
                $treeItem = New-DsaTreeViewItem -Node $result.RootNode
                $Global:SyncHash.DsaTreeView.Items.Add($treeItem) | Out-Null
                $treeItem.IsExpanded = $true
                Set-DsaCurrentNode -Node $result.RootNode
                $statusSuffix = if ($result.Cancelled) { ' (cancelled - partial results)' } else { '' }
                $Global:SyncHash.DsaStatusText.Text = "Done: $($result.FilesScanned) files, $($result.FoldersScanned) folders, $($result.AccessDenied) skipped$statusSuffix"
            } else {
                $Global:SyncHash.DsaStatusText.Text = "Scan failed: $($result.ErrorMessage)"
            }
            $Global:SyncHash.DsaScanBtn.IsEnabled = $true
            $Global:SyncHash.DsaCancelBtn.Visibility = 'Collapsed'
            return
        }

        $p = $Global:SyncHash.DsaProgress
        if ($p) {
            $Global:SyncHash.DsaStatusText.Text = "Scanning... $($p.FilesScanned) files, $($p.FoldersScanned) folders, $($p.AccessDenied) skipped"
        }
    })
    $timer.Start()
    $Global:SyncHash.DsaTimer = $timer

    # Captured on the UI thread (WPF elements are thread-affine) so the background
    # scan thread can pre-warm the treemap cache at the SAME size the real render
    # will use — see Initialize-DsaTreemapCache. A canvas that hasn't been laid out
    # yet (ActualWidth/Height still 0, e.g. module opened for the first time) falls
    # back to Initialize-DsaTreemapCache's own defaults.
    $canvasWidth = $Global:SyncHash.DsaTreemapCanvas.ActualWidth
    $canvasHeight = $Global:SyncHash.DsaTreemapCanvas.ActualHeight

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('SyncHash', $Global:SyncHash)
    $rs.SessionStateProxy.SetVariable('ScanPaths', $scanPaths)
    $rs.SessionStateProxy.SetVariable('IsThisPc', $isThisPc)
    $rs.SessionStateProxy.SetVariable('DsaCanvasWidth', $canvasWidth)
    $rs.SessionStateProxy.SetVariable('DsaCanvasHeight', $canvasHeight)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript({
        $toolkitRoot = $SyncHash.Toolkit.Root
        Get-ChildItem -Path "$toolkitRoot\Core" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
        Get-ChildItem -Path "$toolkitRoot\UI" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
        Get-ChildItem -Path "$toolkitRoot\Modules" -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }

        $entry = @{ Name = 'Storage-Management'; Label = 'Storage Management Scan'; StartTime = Get-Date; EndTime = $null; Status = 'Success'; Detail = '' }

        try {
            $progress = $SyncHash.DsaProgress
            if ($IsThisPc) {
                $rootNode = New-DsaNode -Name 'This PC' -IsDirectory $true
                $rootNode.IsThisPcRoot = $true
                foreach ($p in $ScanPaths) {
                    if ($SyncHash.DsaCancelRequested) { break }
                    $driveNode = Get-DsaVolumeTree -Path $p -ProgressState $progress -CancelFlagRef ([ref]$SyncHash.DsaCancelRequested)
                    $driveNode.Parent = $rootNode
                    $rootNode.Children.Add($driveNode) | Out-Null
                }
                Update-DsaAggregateAcrossDrives -Node $rootNode
            } else {
                $rootNode = Get-DsaVolumeTree -Path $ScanPaths[0] -ProgressState $progress -CancelFlagRef ([ref]$SyncHash.DsaCancelRequested)
            }

            $entry.Detail = "$($progress.FilesScanned) files, $($progress.FoldersScanned) folders scanned"

            # Pre-warm the treemap's node cache here, on this background thread, while
            # the user is still watching "Scanning..." — see Initialize-DsaTreemapCache
            # for why. Warm at the SAME size the real render will use (captured on the
            # UI thread before this runspace started, since WPF elements are
            # thread-affine) — a mismatched size changes which folders cross the
            # recursion threshold, leaving them uncached and forcing their expensive
            # first-time materialization back onto the UI thread during the real
            # render, which is exactly the freeze this cache exists to avoid.
            try {
                $warmWidth = if ($DsaCanvasWidth -gt 0) { $DsaCanvasWidth } else { 800 }
                $warmHeight = if ($DsaCanvasHeight -gt 0) { $DsaCanvasHeight } else { 300 }
                Initialize-DsaTreemapCache -Node $rootNode -Width $warmWidth -Height $warmHeight
            } catch { }

            $entry.EndTime = Get-Date
            $SyncHash.DsaScanResult = [pscustomobject]@{
                Success        = $true
                RootNode       = $rootNode
                FilesScanned   = $progress.FilesScanned
                FoldersScanned = $progress.FoldersScanned
                AccessDenied   = $progress.AccessDenied
                Cancelled      = [bool]$SyncHash.DsaCancelRequested
                ErrorMessage   = $null
                Entry          = $entry
            }
        } catch {
            Write-Log "Storage Management scan failed: $($_.Exception.Message)" -Level Error
            $entry.Status = 'Error'
            $entry.Detail = $_.Exception.Message
            $entry.EndTime = Get-Date
            $SyncHash.DsaScanResult = [pscustomobject]@{
                Success        = $false
                RootNode       = $null
                FilesScanned   = 0
                FoldersScanned = 0
                AccessDenied   = 0
                Cancelled      = $false
                ErrorMessage   = $_.Exception.Message
                Entry          = $entry
            }
        } finally {
            $SyncHash.DsaScanInProgress = $false
        }
    }) | Out-Null

    # $ps/$rs are never disposed once BeginInvoke returns, so every scan (each Scan
    # click, each Refresh) permanently leaks its background thread — left running
    # long enough, the pile-up of idle runspaces contends with a live scan's own
    # Dispatcher.Invoke calls for the UI thread. InvocationStateChanged fires once
    # the script above truly finishes (success, error, or Stop-DsaScan-style stop),
    # so clean up there instead of trying to guess when from outside.
    $ps.BeginInvoke() | Out-Null
    $cleanupHandler = {
        if ($EventArgs.InvocationStateInfo.State -in 'Completed', 'Failed', 'Stopped') {
            Unregister-Event -SourceIdentifier $Event.SourceIdentifier -ErrorAction SilentlyContinue
            Remove-Job -Name $Event.SourceIdentifier -Force -ErrorAction SilentlyContinue
            $Event.MessageData.Ps.Dispose()
            $Event.MessageData.Rs.Close()
            $Event.MessageData.Rs.Dispose()
        }
    }
    Register-ObjectEvent -InputObject $ps -EventName InvocationStateChanged -Action $cleanupHandler -MessageData ([pscustomobject]@{ Ps = $ps; Rs = $rs }) | Out-Null
}

function Remove-DsaNodeAndRefresh {
    param($Node)

    $parent = $Node.Parent
    if (-not $parent) { return }

    Remove-DsaChildFromParent -Parent $parent -Child $Node
    $n = $parent
    while ($n) {
        $sum = ((Get-DsaNodeChildren -Node $n) | Measure-Object -Property Size -Sum).Sum
        $n.Size = if ($sum) { $sum } else { 0 }
        $n = $n.Parent
    }
    if ($parent.TreeViewItem -and $parent.TreeViewItem.Items.Count -gt 0) {
        Expand-DsaTreeViewItemChildren -Item $parent.TreeViewItem -Node $parent
    }
    Set-DsaCurrentNode -Node $parent
}

# ============================================================================
# UI
# ============================================================================

function New-DsaGridColumn {
    param([string]$Header, [string]$Binding, [double]$Width)
    $col = New-Object System.Windows.Controls.GridViewColumn
    $col.Header = $Header
    $col.Width = $Width
    $col.DisplayMemberBinding = New-Object System.Windows.Data.Binding($Binding)
    return $col
}

function Get-StorageManagementUI {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

    $Global:SyncHash.DsaCancelRequested = $false
    $Global:SyncHash.DsaScanInProgress = $false
    $Global:SyncHash.DsaRootNode = $null
    $Global:SyncHash.DsaCurrentNode = $null
    $Global:SyncHash.DsaListMode = 'Browse'
    $Global:SyncHash.DsaSortColumn = 'SizeBytes'
    $Global:SyncHash.DsaSortAscending = $false
    $Global:SyncHash.DsaBrowseFolderPath = $null
    $Global:SyncHash.DsaContextMenuTargetNode = $null

    $rootGrid = New-Object System.Windows.Controls.Grid
    $rootGrid.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    $rootGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $rootGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $rootGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $rootGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))

    # ---- Header ----
    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = 'Storage Management'
    $header.FontSize = 22
    $header.FontWeight = 'Bold'
    $header.Foreground = New-DsaBrush (Get-ToolkitAccent)
    $header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    [System.Windows.Controls.Grid]::SetRow($header, 0)
    $rootGrid.Children.Add($header) | Out-Null

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = 'Scan drives or folders to see what is using disk space. NTFS drives use a fast direct MFT read; other filesystems use a standard recursive scan.'
    $desc.FontSize = 13
    $desc.Foreground = New-DsaBrush '#A6ADC8'
    $desc.TextWrapping = 'Wrap'
    $desc.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    [System.Windows.Controls.Grid]::SetRow($desc, 1)
    $rootGrid.Children.Add($desc) | Out-Null

    # ---- Controls row ----
    $controlsPanel = New-Object System.Windows.Controls.WrapPanel
    $controlsPanel.Orientation = 'Horizontal'
    $controlsPanel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    [System.Windows.Controls.Grid]::SetRow($controlsPanel, 2)
    $rootGrid.Children.Add($controlsPanel) | Out-Null

    $targetCombo = New-Object System.Windows.Controls.ComboBox
    $targetCombo.Width = 220
    $targetCombo.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $targetCombo.Items.Add('This PC (all drives)') | Out-Null
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { $targetCombo.Items.Add($d.Name) | Out-Null }
    }
    $targetCombo.SelectedIndex = 0
    $controlsPanel.Children.Add($targetCombo) | Out-Null

    $browseBtn = New-Object System.Windows.Controls.Button
    $browseBtn.Content = 'Browse Folder...'
    $browseBtn.Padding = [System.Windows.Thickness]::new(10, 4, 10, 4)
    $browseBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $controlsPanel.Children.Add($browseBtn) | Out-Null

    $scanBtn = New-Object System.Windows.Controls.Button
    $scanBtn.Content = 'Scan'
    $scanBtn.Padding = [System.Windows.Thickness]::new(16, 4, 16, 4)
    $scanBtn.Background = New-DsaBrush (Get-ToolkitAccent)
    $scanBtn.Foreground = New-DsaBrush '#1E1E2E'
    $scanBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $controlsPanel.Children.Add($scanBtn) | Out-Null

    $cancelBtn = New-Object System.Windows.Controls.Button
    $cancelBtn.Content = 'Cancel'
    $cancelBtn.Padding = [System.Windows.Thickness]::new(10, 4, 10, 4)
    $cancelBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $cancelBtn.Visibility = 'Collapsed'
    $controlsPanel.Children.Add($cancelBtn) | Out-Null

    $statusText = New-Object System.Windows.Controls.TextBlock
    $statusText.VerticalAlignment = 'Center'
    $statusText.FontSize = 12
    $statusText.Foreground = New-DsaBrush '#A6ADC8'
    $controlsPanel.Children.Add($statusText) | Out-Null

    # ---- Mode toggle + breadcrumb + content (row 3) ----
    $modeOuterGrid = New-Object System.Windows.Controls.Grid
    $modeOuterGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $modeOuterGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $modeOuterGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    [System.Windows.Controls.Grid]::SetRow($modeOuterGrid, 3)
    $rootGrid.Children.Add($modeOuterGrid) | Out-Null

    $togglePanel = New-Object System.Windows.Controls.StackPanel
    $togglePanel.Orientation = 'Horizontal'
    $togglePanel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    [System.Windows.Controls.Grid]::SetRow($togglePanel, 0)
    $modeOuterGrid.Children.Add($togglePanel) | Out-Null

    $rbBrowse = New-Object System.Windows.Controls.RadioButton
    $rbBrowse.Content = 'Browse'
    $rbBrowse.GroupName = 'DsaListMode'
    $rbBrowse.IsChecked = $true
    $rbBrowse.Foreground = New-DsaBrush '#CDD6F4'
    $rbBrowse.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    $togglePanel.Children.Add($rbBrowse) | Out-Null

    $rbTopFiles = New-Object System.Windows.Controls.RadioButton
    $rbTopFiles.Content = 'Top Largest Files'
    $rbTopFiles.GroupName = 'DsaListMode'
    $rbTopFiles.Foreground = New-DsaBrush '#CDD6F4'
    $rbTopFiles.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    $togglePanel.Children.Add($rbTopFiles) | Out-Null

    $rbTopFolders = New-Object System.Windows.Controls.RadioButton
    $rbTopFolders.Content = 'Top Largest Folders'
    $rbTopFolders.GroupName = 'DsaListMode'
    $rbTopFolders.Foreground = New-DsaBrush '#CDD6F4'
    $togglePanel.Children.Add($rbTopFolders) | Out-Null

    $breadcrumbPanel = New-Object System.Windows.Controls.StackPanel
    $breadcrumbPanel.Orientation = 'Horizontal'
    $breadcrumbPanel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    [System.Windows.Controls.Grid]::SetRow($breadcrumbPanel, 1)
    $modeOuterGrid.Children.Add($breadcrumbPanel) | Out-Null

    # ---- Main content: tree | splitter | (list / splitter / treemap) ----
    $contentGrid = New-Object System.Windows.Controls.Grid
    [System.Windows.Controls.Grid]::SetRow($contentGrid, 2)
    $modeOuterGrid.Children.Add($contentGrid) | Out-Null

    $contentGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(220); MinWidth = 120 }))
    $contentGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(4) }))
    $contentGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))

    # Left: folder tree
    $treeBorder = New-Object System.Windows.Controls.Border
    $treeBorder.Background = New-DsaBrush '#FF2D2D44'
    $treeBorder.BorderBrush = New-DsaBrush '#FF3D3D5C'
    $treeBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $treeView = New-Object System.Windows.Controls.TreeView
    $treeView.Background = New-DsaBrush '#FF2D2D44'
    $treeView.BorderThickness = [System.Windows.Thickness]::new(0)
    $treeScroll = New-Object System.Windows.Controls.ScrollViewer
    $treeScroll.Content = $treeView
    $treeScroll.VerticalScrollBarVisibility = 'Auto'
    $treeBorder.Child = $treeScroll
    [System.Windows.Controls.Grid]::SetColumn($treeBorder, 0)
    $contentGrid.Children.Add($treeBorder) | Out-Null

    $vSplitter = New-Object System.Windows.Controls.GridSplitter
    $vSplitter.Width = 4
    $vSplitter.HorizontalAlignment = 'Stretch'
    $vSplitter.Background = New-DsaBrush '#FF3D3D5C'
    [System.Windows.Controls.Grid]::SetColumn($vSplitter, 1)
    $contentGrid.Children.Add($vSplitter) | Out-Null

    # Right: list (top) / treemap (bottom)
    $rightGrid = New-Object System.Windows.Controls.Grid
    [System.Windows.Controls.Grid]::SetColumn($rightGrid, 2)
    $rightGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::new(1.4, [System.Windows.GridUnitType]::Star) }))
    $rightGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::new(4) }))
    $rightGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    $contentGrid.Children.Add($rightGrid) | Out-Null

    $listView = New-Object System.Windows.Controls.ListView
    $listView.Background = New-DsaBrush '#FF2D2D44'
    $listView.Foreground = New-DsaBrush '#CDD6F4'
    $listView.BorderThickness = [System.Windows.Thickness]::new(1)
    $listView.BorderBrush = New-DsaBrush '#FF3D3D5C'
    $gridView = New-Object System.Windows.Controls.GridView
    $gridView.Columns.Add((New-DsaGridColumn 'Name' 'DisplayName' 320)) | Out-Null
    $gridView.Columns.Add((New-DsaGridColumn 'Size' 'SizeDisplay' 100)) | Out-Null
    $gridView.Columns.Add((New-DsaGridColumn '% of Parent' 'PercentDisplay' 170)) | Out-Null
    $gridView.Columns.Add((New-DsaGridColumn 'Files' 'FileCount' 70)) | Out-Null
    $gridView.Columns.Add((New-DsaGridColumn 'Folders' 'FolderCount' 70)) | Out-Null
    $gridView.Columns.Add((New-DsaGridColumn 'Modified' 'ModifiedDisplay' 130)) | Out-Null
    $listView.View = $gridView
    [System.Windows.Controls.Grid]::SetRow($listView, 0)
    $rightGrid.Children.Add($listView) | Out-Null

    $hSplitter = New-Object System.Windows.Controls.GridSplitter
    $hSplitter.Height = 4
    $hSplitter.HorizontalAlignment = 'Stretch'
    $hSplitter.Background = New-DsaBrush '#FF3D3D5C'
    [System.Windows.Controls.Grid]::SetRow($hSplitter, 1)
    $rightGrid.Children.Add($hSplitter) | Out-Null

    $treemapBorder = New-Object System.Windows.Controls.Border
    $treemapBorder.Background = New-DsaBrush '#FF1E1E2E'
    $treemapBorder.BorderBrush = New-DsaBrush '#FF3D3D5C'
    $treemapBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $treemapBorder.ClipToBounds = $true
    $treemapCanvas = New-Object System.Windows.Controls.Canvas
    $treemapBorder.Child = $treemapCanvas
    [System.Windows.Controls.Grid]::SetRow($treemapBorder, 2)
    $rightGrid.Children.Add($treemapBorder) | Out-Null

    # ---- Context menu (shared by list rows and treemap rectangles) ----
    $contextMenu = New-Object System.Windows.Controls.ContextMenu
    $miOpen = New-Object System.Windows.Controls.MenuItem; $miOpen.Header = 'Open'
    $miOpenFolder = New-Object System.Windows.Controls.MenuItem; $miOpenFolder.Header = 'Open Containing Folder in Explorer'
    $miCopyPath = New-Object System.Windows.Controls.MenuItem; $miCopyPath.Header = 'Copy Path'
    $miSep = New-Object System.Windows.Controls.Separator
    $miDelete = New-Object System.Windows.Controls.MenuItem; $miDelete.Header = 'Delete to Recycle Bin'
    $miRefresh = New-Object System.Windows.Controls.MenuItem; $miRefresh.Header = 'Refresh'
    $contextMenu.Items.Add($miOpen) | Out-Null
    $contextMenu.Items.Add($miOpenFolder) | Out-Null
    $contextMenu.Items.Add($miCopyPath) | Out-Null
    $contextMenu.Items.Add($miSep) | Out-Null
    $contextMenu.Items.Add($miDelete) | Out-Null
    $contextMenu.Items.Add($miRefresh) | Out-Null

    # ---- Store control refs so the top-level view-update functions can reach them ----
    $Global:SyncHash.DsaTargetCombo     = $targetCombo
    $Global:SyncHash.DsaScanBtn         = $scanBtn
    $Global:SyncHash.DsaCancelBtn       = $cancelBtn
    $Global:SyncHash.DsaStatusText      = $statusText
    $Global:SyncHash.DsaTreeView        = $treeView
    $Global:SyncHash.DsaListView        = $listView
    $Global:SyncHash.DsaTreemapCanvas   = $treemapCanvas
    $Global:SyncHash.DsaBreadcrumbPanel = $breadcrumbPanel
    $Global:SyncHash.DsaContextMenu     = $contextMenu

    # ============================================================
    # Event wiring — every handler either only touches $Global:SyncHash /
    # $sender / $e, or calls a top-level function above, so none of them
    # need .GetNewClosure().
    # ============================================================

    $rbBrowse.Add_Checked({ $Global:SyncHash.DsaListMode = 'Browse'; if ($Global:SyncHash.DsaCurrentNode) { Update-DsaListView -Node $Global:SyncHash.DsaCurrentNode } })
    $rbTopFiles.Add_Checked({ $Global:SyncHash.DsaListMode = 'TopFiles'; if ($Global:SyncHash.DsaCurrentNode) { Update-DsaListView -Node $Global:SyncHash.DsaCurrentNode } })
    $rbTopFolders.Add_Checked({ $Global:SyncHash.DsaListMode = 'TopFolders'; if ($Global:SyncHash.DsaCurrentNode) { Update-DsaListView -Node $Global:SyncHash.DsaCurrentNode } })

    $treemapCanvas.Add_SizeChanged({
        if ($Global:SyncHash.DsaCurrentNode) { Update-DsaTreemap -Node $Global:SyncHash.DsaCurrentNode }
    })

    # Column-header click-to-sort (mirrors Network-Diagnostics.ps1's header pattern)
    $listView.AddHandler(
        [System.Windows.Controls.GridViewColumnHeader]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($sender, $e)
            $colHeader = $e.OriginalSource -as [System.Windows.Controls.GridViewColumnHeader]
            if (-not $colHeader -or -not $colHeader.Column) { return }
            $bindingPath = $colHeader.Column.DisplayMemberBinding.Path.Path
            $sortProp = if ($bindingPath -eq 'SizeDisplay') { 'SizeBytes' } else { $bindingPath }
            if ($Global:SyncHash.DsaSortColumn -eq $sortProp) {
                $Global:SyncHash.DsaSortAscending = -not $Global:SyncHash.DsaSortAscending
            } else {
                $Global:SyncHash.DsaSortColumn = $sortProp
                $Global:SyncHash.DsaSortAscending = $false
            }
            if ($Global:SyncHash.DsaCurrentNode) { Update-DsaListView -Node $Global:SyncHash.DsaCurrentNode }
        }
    )

    $listView.Add_MouseDoubleClick({
        param($sender, $e)
        $row = $sender.SelectedItem
        if (-not $row) { return }
        if ($row.Node.IsDirectory) { Set-DsaCurrentNode -Node $row.Node }
        else { Open-DsaContainingFolder -Node $row.Node }
    })
    $listView.Add_PreviewMouseRightButtonUp({
        param($sender, $e)
        $row = $sender.SelectedItem
        if ($row) { $Global:SyncHash.DsaContextMenuTargetNode = $row.Node }
    })

    $browseBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select a folder to scan'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $Global:SyncHash.DsaBrowseFolderPath = $dlg.SelectedPath
            $Global:SyncHash.DsaStatusText.Text = "Ready to scan: $($dlg.SelectedPath)"
        }
    })

    $targetCombo.Add_SelectionChanged({
        # A fresh drive/"This PC" pick always overrides a prior Browse Folder choice
        $Global:SyncHash.DsaBrowseFolderPath = $null
    })

    $scanBtn.Add_Click({ Start-DsaScan })
    $cancelBtn.Add_Click({
        $Global:SyncHash.DsaCancelRequested = $true
        $Global:SyncHash.DsaStatusText.Text = 'Cancelling...'
    })

    $miOpen.Add_Click({
        $node = $Global:SyncHash.DsaContextMenuTargetNode
        if (-not $node) { return }
        if ($node.IsDirectory) { Set-DsaCurrentNode -Node $node } else { Open-DsaContainingFolder -Node $node }
    })
    $miOpenFolder.Add_Click({
        $node = $Global:SyncHash.DsaContextMenuTargetNode
        if ($node) { Open-DsaContainingFolder -Node $node }
    })
    $miCopyPath.Add_Click({
        $node = $Global:SyncHash.DsaContextMenuTargetNode
        if ($node) { [System.Windows.Clipboard]::SetText($node.FullPath) }
    })
    $miRefresh.Add_Click({
        if ($Global:SyncHash.DsaCurrentNode) {
            $Global:SyncHash.DsaBrowseFolderPath = $Global:SyncHash.DsaCurrentNode.FullPath
            Start-DsaScan
        }
    })
    $miDelete.Add_Click({
        $node = $Global:SyncHash.DsaContextMenuTargetNode
        if (-not $node) { return }

        $kind = if ($node.IsDirectory) { 'folder' } else { 'file' }
        $confirm = [System.Windows.MessageBox]::Show(
            "Send this $kind to the Recycle Bin?`n`n$($node.FullPath)`n$(Format-DsaSize $node.Size)",
            'Confirm Delete', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }

        try {
            Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
            if ($node.IsDirectory) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($node.FullPath, 'OnlyErrorDialogs', 'SendToRecycleBin')
            } else {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($node.FullPath, 'OnlyErrorDialogs', 'SendToRecycleBin')
            }
        } catch {
            [System.Windows.MessageBox]::Show("Failed to delete: $($_.Exception.Message)", 'Delete Failed', 'OK', 'Error') | Out-Null
            return
        }

        Write-Log "Deleted '$($node.FullPath)' to Recycle Bin." -Level Success
        Remove-DsaNodeAndRefresh -Node $node
    })

    # Deferred to idle priority so it never delays the module UI itself from
    # appearing — it'll run once the UI thread is otherwise idle, which in practice
    # means during the several seconds a scan takes, well before there's a treemap
    # to draw. See Invoke-DsaWpfWarmup for why this exists.
    try {
        $Global:SyncHash.Window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
            [action]{ Invoke-DsaWpfWarmup }
        ) | Out-Null
    } catch { }

    return $rootGrid
}
