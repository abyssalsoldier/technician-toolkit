# Agent: ModuleMetadata.ps1
# Reads module registration metadata by PARSING module files (PowerShell AST); a module file is never
# executed here. Shared by tools\OverlayValidation.ps1 (wizard, Test-ClientOverlay, CI) and
# LockedPayload.ps1 (locked exe / USB builds, which also run inside a shipped kit where tools\ is absent).
# NOT loaded at toolkit startup; dot-sourced on demand.

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

function Get-OvModuleSecrets {
    # Secret names a parsed module (Read-OvModuleFile) needs:
    #   Declared   : the Register-* key  Secrets = @('Name1', 'Name2')  (or a single 'Name')
    #   Used       : literal names passed to Get-ToolkitSecret '<Name>' anywhere in the file
    #   All        : both, unique, in that order
    #   Undeclared : used but not declared
    #   Invalid    : declared entries that are not plain names (computed values, bad characters)
    param([Parameter(Mandatory)][hashtable]$Parsed)
    $nameRx = '^[A-Za-z][A-Za-z0-9_]{0,63}$'
    $declared = @(); $invalid = @()
    $reg = $Parsed.Registrations | Select-Object -First 1
    if ($reg) {
        $ht = $Parsed.Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $reg.FunctionName }, $true).Body.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        $pair = if ($ht) { $ht.KeyValuePairs | Where-Object { $_.Item1.Extent.Text.Trim("'`"") -eq 'Secrets' } | Select-Object -First 1 }
        if ($pair) {
            $items = @($pair.Item2.FindAll({ param($n)
                ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or $n -is [System.Management.Automation.Language.VariableExpressionAst]) -and
                -not ($n.Parent -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) }, $true))
            foreach ($i in $items) {
                if ($i -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $i.Value -match $nameRx) { $declared += $i.Value }
                else { $invalid += $i.Extent.Text }
            }
        }
    }
    $used = @($Parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-ToolkitSecret' }, $true) | ForEach-Object {
        $arg = $_.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] } | Select-Object -First 1
        if ($arg -and $arg.Value -match $nameRx) { $arg.Value }
    })
    $declared = @($declared | Select-Object -Unique); $used = @($used | Select-Object -Unique)
    return @{
        Declared   = $declared
        Used       = $used
        All        = @(@($declared) + @($used) | Select-Object -Unique)
        Undeclared = @($used | Where-Object { $declared -notcontains $_ })
        Invalid    = $invalid
    }
}
