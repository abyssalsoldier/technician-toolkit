# Client module: Example-Module.ps1
# Template for client-specific modules (for example an RMM agent install/check).
# Copy it, rename the file and every "ClientExample" below, then run tools\Test-ClientOverlay.ps1.
#
# Rules (see AGENTS.md):
#   - Only function definitions at the top level. Modules are loaded on every launch and in every
#     background task, so nothing may run at load time.
#   - Long work runs in the background (Start-ModuleInBackground or your own runspace), never on the UI thread.
#   - The toolkit may run as SYSTEM via ConnectWise Toolbox: no user-profile paths, no interactive prompts.
#   - Use Get-ToolkitAccent / New-ToolkitBrush for the brand color instead of hardcoding hex values.
#   - Never hardcode secrets (tenant keys, tokens). List each one in Secrets = @(...) below and read it with
#     Get-ToolkitSecret 'Name' (never log it). The Client Setup wizard adds listed secrets to its Secrets page,
#     where their values are entered. A module that reads secrets must be locked.
#
# Secrets this module needs: none

function Register-ClientExample {
    @{
        Name         = 'ClientExample'            # unique; reusing a core Name replaces that core module
        Label        = 'Client Example'           # menu text
        Description  = 'Template client module'
        RequiresAuth = $true                      # locked until the toolkit password is entered (SFX/USB)
        SortOrder    = 90                         # menu position; core modules use 20-50
        EntryPoint   = 'Start-ClientExample'      # runs in a background runspace
        UIDefinition = 'Get-ClientExampleUI'      # optional; omit for a default "Run" button
        Secrets      = @()                        # every secret this module reads, e.g. @('ClientExampleSiteKey')
    }
}

function Get-ClientExampleUI {
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)

    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = 'Client Example'
    $header.FontSize = 20
    $header.FontWeight = 'Bold'
    $header.Foreground = New-ToolkitBrush               # brand accent
    $header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $panel.Children.Add($header) | Out-Null

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = 'Replace this with your own module, for example installing and checking your RMM agent.'
    $desc.TextWrapping = 'Wrap'
    $desc.Foreground = New-ToolkitBrush '#A6ADC8'
    $desc.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    $panel.Children.Add($desc) | Out-Null

    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = 'Run Example'
    $btn.Padding = [System.Windows.Thickness]::new(16, 6, 16, 6)
    $btn.HorizontalAlignment = 'Left'
    $btn.Add_Click({
        # Runs Start-ClientExample in a background runspace, logged in the Session Report
        Start-ModuleInBackground -Module (Register-ClientExample)
    })
    $panel.Children.Add($btn) | Out-Null

    return $panel
}

function Start-ClientExample {
    # Background runspace: Core, UI helpers (Write-Log) and all modules are already loaded.
    # Client files live under (Get-ToolkitClientRoot), e.g. Join-Path (Get-ToolkitClientRoot) 'CustomInstallers\agent.msi'
    Write-Log "Client Example running on $env:COMPUTERNAME as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Level Info
    Write-Log "Client folder: $(Get-ToolkitClientRoot)" -Level Info
    Write-Log 'Client Example finished.' -Level Success
}
