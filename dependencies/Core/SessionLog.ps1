# Core: SessionLog.ps1
# Session log and the Session Report text (shown by the GUI's Session Report dialog)

function Initialize-SessionLog {
    $script:Toolkit.Session = @{
        StartTime      = Get-Date
        ComputerName   = $env:COMPUTERNAME
        ScriptVersion  = $script:Toolkit.Version
        ModulesRun     = [System.Collections.ArrayList]::new()
        Errors         = [System.Collections.ArrayList]::new()
    }
}

function Get-SessionReport {
    $log = $script:Toolkit.Session
    $duration = (Get-Date) - $log.StartTime

    $report = @()
    $report += "============================================"
    $report += "  ENDPOINT BUILD SESSION REPORT"
    $report += "============================================"
    $report += ""
    $report += "Computer Name  : $($log.ComputerName)"
    $report += "Toolkit        : $(Get-ToolkitProductName)"
    $report += "Toolkit Version: $($log.ScriptVersion)"
    if ($script:Toolkit.ClientVersion) { $report += "Core Version   : $($script:Toolkit.CoreVersion)" }
    $support = Get-ToolkitBrandingValue 'SupportContact'
    if ($support) { $report += "Support        : $support" }
    $report += "Session Start  : $($log.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    $report += "Session End    : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    $report += "Duration       : $($duration.ToString('hh\:mm\:ss'))"
    $report += ""

    $report += "--- Modules Executed ---"
    $report += ""

    if ($log.ModulesRun.Count -eq 0) {
        $report += "  (none)"
    } else {
        foreach ($m in $log.ModulesRun) {
            $moduleDuration = if ($m.EndTime) { ($m.EndTime - $m.StartTime).ToString('mm\:ss') } else { "??" }
            $statusIcon = switch ($m.Status) {
                "Success" { "[OK]" }
                "Skipped" { "[SKIP]" }
                "Error"   { "[FAIL]" }
            }
            $report += "  $statusIcon $($m.Label) ($moduleDuration)"
            if ($m.Detail) {
                $report += "        $($m.Detail)"
            }
        }
    }

    if ($log.Errors.Count -gt 0) {
        $report += ""
        $report += "--- Errors ---"
        $report += ""
        foreach ($err in $log.Errors) {
            $report += "  * $err"
        }
    }

    # Include full activity log if available
    if ($log.LogEntries -and $log.LogEntries.Count -gt 0) {
        $report += ""
        $report += "--- Activity Log ---"
        $report += ""
        foreach ($entry in $log.LogEntries) {
            $report += "  $entry"
        }
    }

    $report += ""
    $report += "============================================"

    return ($report -join "`r`n")
}
