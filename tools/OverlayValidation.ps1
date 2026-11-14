# tools/OverlayValidation.ps1
# Shared validation for the client overlay, used by tools\Test-ClientOverlay.ps1 and the Client Setup
# wizard (tools\ClientSetup). Repo-only: never shipped, never loaded by the toolkit at runtime.
#
# Modules are inspected by PARSING them (PowerShell AST) - a module file is never executed here, so a
# file picked in the wizard can't run code just by being imported, and the checks work on Linux CI.

function Get-OvAstLiteral {
    # Literal value of a hashtable value AST: string, number, $true/$false. IsLiteral=$false when computed.
    param($ValueAst)
    $expr = $ValueAst
    if ($expr -is [System.Management.Automation.Language.PipelineAst] -and $expr.PipelineElements.Count -eq 1) { $expr = $expr.PipelineElements[0] }
    if ($expr -is [System.Management.Automation.Language.CommandExpressionAst]) { $expr = $expr.Expression }
    if ($expr -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return @{ IsLiteral = $true; Value = $expr.Value } }
    if ($expr -is [System.Management.Automation.Language.ConstantExpressionAst]) { return @{ IsLiteral = $true; Value = $expr.Value } }
    if ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
        switch ($expr.VariablePath.UserPath) { 'true' { return @{ IsLiteral = $true; Value = $true } } 'false' { return @{ IsLiteral = $true; Value = $false } } }
    }
    return @{ IsLiteral = $false; Value = $ValueAst.Extent.Text }
}

function Read-OvModuleFile {
    # Parses a module file. Returns Errors (parse), Functions (names), Registrations (one per Register-*:
    # FunctionName + Meta hashtable of literal values + NonLiteral key list), and the AST.
    param([Parameter(Mandatory)][string]$File)
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$parseErrors)
    $functions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $regs = @()
    foreach ($r in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Register-*' }, $true)) {
        $meta = @{}; $nonLiteral = @()
        $ht = $r.Body.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        if ($ht) {
            foreach ($pair in $ht.KeyValuePairs) {
                $key = $pair.Item1.Extent.Text.Trim("'`"")
                $lit = Get-OvAstLiteral $pair.Item2
                if ($lit.IsLiteral) { $meta[$key] = $lit.Value } else { $meta[$key] = $lit.Value; $nonLiteral += $key }
            }
        }
        $regs += @{ FunctionName = $r.Name; Meta = $meta; NonLiteral = $nonLiteral; HasHashtable = [bool]$ht }
    }
    return @{ Ast = $ast; Errors = @($parseErrors); Functions = $functions; Registrations = $regs }
}

function Get-OvCoreInventory {
    # Core modules and functions, from dependencies/Modules (parsed, not executed).
    #   Modules  : list of @{ Name; Label; RequiresAuth; File; Functions }
    #   Functions: hashtable functionName -> core module Name (or file name)
    param([Parameter(Mandatory)][string]$Root)
    $modules = @(); $functions = @{}
    foreach ($f in Get-ChildItem (Join-Path $Root 'dependencies/Modules') -Filter '*.ps1' -File | Sort-Object Name) {
        $p = Read-OvModuleFile $f.FullName
        $reg = $p.Registrations | Select-Object -First 1
        $name = if ($reg -and $reg.Meta.Name) { $reg.Meta.Name } else { $f.BaseName }
        foreach ($fn in $p.Functions) { $functions[$fn] = $name }
        if ($reg) {
            $modules += @{ Name = $name; Label = $reg.Meta.Label; RequiresAuth = [bool]$reg.Meta.RequiresAuth; SortOrder = $reg.Meta.SortOrder; File = $f.Name; Functions = $p.Functions }
        }
    }
    return @{ Modules = @($modules | Sort-Object { $_.SortOrder }); Functions = $functions }
}

function Find-OvCoreWrites {
    # Best-effort static scan for code that writes, moves or deletes inside core folders.
    # (core-manifest.json is the hard backstop; this catches the obvious cases at import time.)
    param([Parameter(Mandatory)]$Ast)
    $hits = @()
    $writeCmds = 'Set-Content', 'Add-Content', 'Out-File', 'Copy-Item', 'Move-Item', 'Remove-Item', 'New-Item', 'Rename-Item', 'Clear-Content', 'Expand-Archive', 'Export-Csv', 'Export-Clixml', 'sc', 'ac', 'cp', 'copy', 'mv', 'move', 'rm', 'del', 'ri', 'ni', 'ren'
    $corePath = '(Toolkit\.Root|\$toolkitRoot|\$depsRoot|\bdependencies\b|PSScriptRoot\s*[\\/,''"]\s*\.\.|Toolkit\.Parent(?![^\r\n]*client))'
    foreach ($cmd in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        if ($name -and $writeCmds -contains $name -and $cmd.Extent.Text -match $corePath) {
            $hits += "line $($cmd.Extent.StartLineNumber): $($cmd.Extent.Text.Split("`n")[0].Trim())"
        }
    }
    foreach ($m in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if ($m.Member.Extent.Text -match '^(WriteAll\w*|AppendAll\w*|Delete|Move|Copy|Replace|Create\w*|ExtractToDirectory|CreateFromDirectory)$' -and $m.Extent.Text -match $corePath) {
            $hits += "line $($m.Extent.StartLineNumber): $($m.Extent.Text.Split("`n")[0].Trim())"
        }
    }
    return $hits
}

function Test-OvClientModule {
    # Checks one client module file. Returns @{ Errors; Warnings; Infos; Meta; ReplacesCore }.
    #   -CoreInventory     : from Get-OvCoreInventory
    #   -OtherClientNames  : module Names of the OTHER client modules (duplicate check)
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][hashtable]$CoreInventory,
        [string[]]$OtherClientNames = @()
    )
    $errors = @(); $warnings = @(); $infos = @(); $meta = $null; $replaces = $null
    $p = Read-OvModuleFile $File
    if ($p.Errors.Count -gt 0) {
        foreach ($e in $p.Errors) { $errors += "line $($e.Extent.StartLineNumber): $($e.Message)" }
        return @{ Errors = $errors; Warnings = $warnings; Infos = $infos; Meta = $null; ReplacesCore = $null }
    }

    # Registration
    if ($p.Registrations.Count -eq 0) { $errors += 'No Register-<Name> function - the module would not appear in the menu.' }
    elseif ($p.Registrations.Count -gt 1) { $errors += "More than one Register-* function ($(($p.Registrations | ForEach-Object FunctionName) -join ', ')). Use one module per file." }
    else {
        $reg = $p.Registrations[0]
        $meta = $reg.Meta
        if (-not $reg.HasHashtable) { $errors += "$($reg.FunctionName) must return a hashtable @{ Name = ...; Label = ...; EntryPoint = ...; SortOrder = ... }." }
        foreach ($key in 'Name', 'Label', 'EntryPoint', 'SortOrder') {
            if (-not $meta.ContainsKey($key) -or "$($meta[$key])" -eq '') { $errors += "Register function is missing '$key'." }
        }
        foreach ($key in $reg.NonLiteral) {
            if ($key -in 'Name', 'EntryPoint', 'UIDefinition', 'SortOrder') { $errors += "'$key' must be a plain value (not computed) so it can be verified." }
        }
        if ($meta.SortOrder -and -not ($meta.SortOrder -is [int] -or $meta.SortOrder -is [double] -or $meta.SortOrder -is [long])) { $errors += 'SortOrder must be a number.' }
        if ($meta.Name -and "$($meta.Name)" -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]*$') { $errors += "Name '$($meta.Name)' may only contain letters, digits, spaces, '.', '_' and '-'." }
        if ($meta.EntryPoint -and $p.Functions -notcontains $meta.EntryPoint) { $errors += "EntryPoint '$($meta.EntryPoint)' is not defined in this file." }
        if ($meta.UIDefinition -and $p.Functions -notcontains $meta.UIDefinition) { $errors += "UIDefinition '$($meta.UIDefinition)' is not defined in this file." }
        if ($meta.MinCoreVersion) { $v = $null; if (-not [version]::TryParse("$($meta.MinCoreVersion)", [ref]$v)) { $errors += "MinCoreVersion '$($meta.MinCoreVersion)' is not a version like 2.1.0." } }
        if ($meta.Name -and $OtherClientNames -contains $meta.Name) { $errors += "Another client module already uses the Name '$($meta.Name)'." }
        if ($meta.Name -and ($CoreInventory.Modules | Where-Object { $_.Name -eq $meta.Name })) {
            $replaces = $meta.Name
            $infos += "Replaces the core module '$($meta.Name)'."
        }
    }

    # Function collisions with core: allowed only for the functions of the core module this one replaces
    foreach ($fn in $p.Functions) {
        if ($CoreInventory.Functions.ContainsKey($fn)) {
            $owner = $CoreInventory.Functions[$fn]
            if ($replaces -and $owner -eq $replaces) { $infos += "Overrides $fn of the core module it replaces." }
            else { $errors += "Defines '$fn', which already exists in core module '$owner'. Rename it (prefix with your company name), or give this module the Name '$owner' to replace that module." }
        }
    }

    # Writes into core
    foreach ($h in Find-OvCoreWrites -Ast $p.Ast) { $errors += "Writes into core folders ($h). Modules may only write to Get-ToolkitClientDataPath or C:\_INFO." }

    # Load-time work and SYSTEM / ConnectWise safety
    foreach ($stmt in $p.Ast.EndBlock.Statements) {
        $isFunction = $stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]
        $isSimpleAssign = $stmt -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            -not $stmt.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        if (-not $isFunction -and -not $isSimpleAssign) {
            $warnings += "line $($stmt.Extent.StartLineNumber) runs code when the file loads (every launch and every background task). Move it into a function."
        }
    }
    $text = $p.Ast.Extent.Text
    if ($text -match '\bRead-Host\b') { $warnings += 'Uses Read-Host - console prompts never appear (the console is hidden) and block ConnectWise/SYSTEM runs. Use WPF controls.' }
    if ($text -match 'HKCU:|\$env:USERPROFILE|\$env:APPDATA|\$HOME\b') { $warnings += 'Uses the current user profile (HKCU / USERPROFILE / APPDATA) - under ConnectWise the toolkit may run as SYSTEM.' }
    $size = (Get-Item -LiteralPath $File).Length
    if ($size -gt 1MB) { $warnings += "Module file is $([math]::Round($size / 1MB, 1)) MB - keep scripts small; put binaries in CustomInstallers." }

    return @{ Errors = $errors; Warnings = $warnings; Infos = $infos; Meta = $meta; ReplacesCore = $replaces }
}

function Test-OvBranding {
    # Checks client\branding.json. Returns @{ Errors; Warnings; Infos; Branding (PSCustomObject or $null) }.
    param(
        [Parameter(Mandatory)][string]$ClientRoot,
        [string[]]$KnownModuleNames = @()
    )
    $errors = @(); $warnings = @(); $infos = @(); $b = $null
    $path = Join-Path $ClientRoot 'branding.json'
    if (-not (Test-Path $path)) { return @{ Errors = @('client\branding.json is missing.'); Warnings = @(); Infos = @(); Branding = $null } }
    try { $b = Get-Content $path -Raw | ConvertFrom-Json } catch { return @{ Errors = @("client\branding.json is not valid JSON: $($_.Exception.Message)"); Warnings = @(); Infos = @(); Branding = $null } }

    $known = 'ProductName', 'AccentColor', 'Logo', 'SupportContact', 'UpdateSource', 'UpdateBaseUrl', 'DisabledModules', 'LockedModules', 'ExeName'
    foreach ($prop in $b.PSObject.Properties.Name) {
        if ($known -notcontains $prop -and $prop -notlike '_*') { $warnings += "Unknown key '$prop' (ignored). Known keys: $($known -join ', ')" }
    }
    if ($b.ProductName) { $infos += "ProductName: $($b.ProductName)" } else { $warnings += 'ProductName not set - the core name will be shown.' }
    if ($b.AccentColor) {
        if ($b.AccentColor -match '^#[0-9A-Fa-f]{6}$') { $infos += "AccentColor: $($b.AccentColor)" } else { $errors += "AccentColor '$($b.AccentColor)' must be #RRGGBB." }
    }

    $source = if ($b.UpdateSource) { "$($b.UpdateSource)".ToLower() } elseif ($b.UpdateBaseUrl) { 'custom' } else { 'none' }
    switch ($source) {
        'core'   { $infos += 'Updates: automatic core updates (your client folder is kept).' }
        'none'   { $warnings += 'Updates: off - USB toolkits will not self-update.' }
        'custom' {
            if (-not $b.UpdateBaseUrl) { $errors += 'UpdateSource is "custom" but UpdateBaseUrl is empty.' }
            elseif ($b.UpdateBaseUrl -notmatch '^https://\S+$') { $errors += 'UpdateBaseUrl must be an https URL.' }
            elseif ($b.UpdateBaseUrl -match 'abyssalsoldier/Endpoint-toolkit') { $errors += 'UpdateBaseUrl points at the CORE feed. Use UpdateSource "core" for automatic core updates instead.' }
            else {
                $infos += "Updates: own feed $($b.UpdateBaseUrl)"
                if ($b.UpdateBaseUrl -notmatch '/releases/latest/download/?$') { $warnings += 'UpdateBaseUrl usually ends with /releases/latest/download (GitHub Releases).' }
            }
        }
        default { $errors += "UpdateSource '$($b.UpdateSource)' must be core, custom or none." }
    }

    if ($b.Logo) {
        $logo = [System.IO.Path]::GetFullPath((Join-Path $ClientRoot $b.Logo))
        if (-not $logo.StartsWith($ClientRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $errors += 'Logo must be a path inside client\.' }
        elseif (-not (Test-Path $logo -PathType Leaf)) { $errors += "Logo file not found: client\$($b.Logo)" }
        elseif ((Get-Item $logo).Length -gt 256KB) { $errors += "Logo is $([math]::Round((Get-Item $logo).Length / 1KB)) KB; the limit is 256 KB." }
        else { $infos += "Logo: client\$($b.Logo)" }
    }
    if ($b.ExeName) {
        if ($b.ExeName -notmatch '^[A-Za-z0-9._-]+$') { $errors += "ExeName '$($b.ExeName)' may only contain letters, digits, '.', '_' and '-'." }
        else { $warnings += "ExeName '$($b.ExeName)' renames the exe - update any ConnectWise Toolbox entries that run the old name." }
    }
    foreach ($listKey in 'DisabledModules', 'LockedModules') {
        foreach ($n in @($b.$listKey)) {
            if (-not $n) { continue }
            if ($listKey -eq 'LockedModules' -and $n -eq '*') { $infos += 'Locked: all modules'; continue }
            if ($KnownModuleNames.Count -and $KnownModuleNames -notcontains $n) { $warnings += "$listKey '$n' does not match any module Name." }
        }
    }
    return @{ Errors = $errors; Warnings = $warnings; Infos = $infos; Branding = $b }
}

function Test-OvClientOverlay {
    # Full overlay check (branding, version, every module, payload). Returns @{ Errors; Warnings; Infos }
    # with section-prefixed messages. Does not include the core integrity check (see CoreIntegrity.ps1).
    param([Parameter(Mandatory)][string]$Root)
    $errors = @(); $warnings = @(); $infos = @()
    $clientRoot = Join-Path $Root 'client'
    if (-not (Test-Path $clientRoot -PathType Container)) { return @{ Errors = @(); Warnings = @(); Infos = @('No client folder - core-only checkout.') } }
    $core = Get-OvCoreInventory -Root $Root

    # Modules first (their Names feed the branding list checks)
    $files = @(Get-ChildItem (Join-Path $clientRoot 'Modules') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $names = @{}
    foreach ($f in $files) { $r = Read-OvModuleFile $f.FullName; $reg = $r.Registrations | Select-Object -First 1; if ($reg -and $reg.Meta.Name) { $names[$f.FullName] = $reg.Meta.Name } }
    foreach ($f in $files) {
        $others = @($names.Keys | Where-Object { $_ -ne $f.FullName } | ForEach-Object { $names[$_] })
        $r = Test-OvClientModule -File $f.FullName -CoreInventory $core -OtherClientNames $others
        $errors   += $r.Errors   | ForEach-Object { "Modules\$($f.Name): $_" }
        $warnings += $r.Warnings | ForEach-Object { "Modules\$($f.Name): $_" }
        $infos    += $r.Infos    | ForEach-Object { "Modules\$($f.Name): $_" }
        if ($r.Errors.Count -eq 0 -and $r.Meta) { $infos += "Modules\$($f.Name): OK -> $($r.Meta.Name) ('$($r.Meta.Label)')" }
    }

    $known = @($core.Modules | ForEach-Object { $_.Name }) + @($names.Values)
    $b = Test-OvBranding -ClientRoot $clientRoot -KnownModuleNames $known
    $errors += $b.Errors | ForEach-Object { "branding.json: $_" }
    $warnings += $b.Warnings | ForEach-Object { "branding.json: $_" }
    $infos += $b.Infos | ForEach-Object { "branding.json: $_" }

    $verPath = Join-Path $clientRoot 'version.txt'
    $v = $null
    if (-not (Test-Path $verPath)) { $errors += 'version.txt: missing.' }
    elseif (-not [version]::TryParse((Get-Content $verPath -Raw).Trim(), [ref]$v)) { $errors += "version.txt: '$((Get-Content $verPath -Raw).Trim())' is not a version like 1.0.0." }
    else { $infos += "version.txt: $v" }

    # Payload = everything in client\ except the wizard undo bin and module working data (never shipped)
    $skip = @((Join-Path $clientRoot '_removed'), (Join-Path $clientRoot 'Data'))
    $all = @(Get-ChildItem $clientRoot -Recurse -File -Force | Where-Object { $fp = $_.FullName; -not ($skip | Where-Object { $fp.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }) })
    $mb = [math]::Round((($all | Measure-Object Length -Sum).Sum) / 1MB, 2)
    $infos += "Payload: client\ is $mb MB in $($all.Count) files."
    foreach ($big in $all | Where-Object { $_.Length -gt 25MB }) { $warnings += "Payload: large file $($big.Name) ($([math]::Round($big.Length / 1MB)) MB) - ConnectWise Toolbox uploads get slower." }
    foreach ($s in $all | Where-Object { $_.Name -like '*.key' -or $_.Name -in '.toolkit-key', '.sfx-key' }) { $errors += "Payload: key file must not be in client\: $($s.Name)" }

    return @{ Errors = $errors; Warnings = $warnings; Infos = $infos }
}
