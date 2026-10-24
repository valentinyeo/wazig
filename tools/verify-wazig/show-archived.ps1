function Save-ArchivedSwitch($Session, [string]$Name, [bool]$Enabled, [int]$Count, [int]$Archived) {
    $null = Wait-Until {
        $state = Read-Control $Session status
        $rows = @((Read-Control $Session chats).chats)
        $state.include_archived -eq $Enabled -and -not $state.show_archived -and
            $rows.Count -eq $Count -and @($rows | Where-Object archived).Count -eq $Archived -and
            @($rows | Where-Object { $_.archived -and $_.archive_label -notin @('Archived', 'Kept archived') }).Count -eq 0
    } "show-archived $Name"
    Save-Screen $Session $Name
    Hub-Pass $Session $Name | Out-Null
}

function Read-ArchivedSwitchTooltip($Session) {
    Add-Type -Path "$PSScriptRoot/menus.cs"
    $button = Get-Edit (Get-Window $Session) '1146'
    $bounds = $button.Current.BoundingRectangle
    $null = Get-App $Session
    [VerifyMenus]::Hover($Session.pid, [int]($bounds.Left + 2), [int]($bounds.Top + 2))
    [VerifyMenus]::Hover($Session.pid, [int]($bounds.Left + $bounds.Width / 2), [int]($bounds.Top + $bounds.Height / 2))
    $text = Wait-Until {
        $condition = [Windows.Automation.AndCondition]::new(
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$Session.pid),
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ClassNameProperty, 'tooltips_class32')
        )
        foreach ($tip in [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
            if (-not $tip.Current.IsOffscreen -and $tip.Current.Name.Contains('Alt+A')) { return $tip.Current.Name }
        }
        $native = [VerifyMenus]::Find($Session.pid, 'tooltips_class32')
        if ($native -ne [IntPtr]::Zero) {
            $label = Read-EditText $native
            if ($label.Contains('Alt+A')) { return $label }
        }
    } 'Show archived tooltip contains Alt+A'
    @{ text = $text; control = '1146'; pid = $Session.pid } | ConvertTo-Json | Set-Content (Join-Path $Session.evidence 'show-archived-tooltip.json')
    Save-Screen $Session tooltip
}

function Invoke-ShowArchivedJourney($Session, $Start) {
    Send-Keys $Session '%i'
    $null = Wait-Until { (Read-Control $Session status).current_view.inbox } 'combined inbox'
    Invoke-PaletteCommand $Session 'Toggle unread chats'
    $null = Wait-Until { (Read-Control $Session status).unread_only } 'inbox unread filter enabled'
    Save-ArchivedSwitch $Session inbox-off $false 5 0
    Send-Keys $Session '%a'
    Save-ArchivedSwitch $Session inbox-on $true 10 5
    Assert-That (@((Read-Control $Session chats).chats | Where-Object { -not $_.unread }).Count -eq 0) 'Inbox mixed mode included a read chat'
    Read-ArchivedSwitchTooltip $Session
    Invoke-PaletteCommand $Session 'Toggle unread chats'
    $views = @((Read-Control $Session status).view_order)
    Assert-That ($views.Count -eq 5) 'Expected two WhatsApp and three other account views'
    $views | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Session.evidence 'show-archived-views.json')
    for ($position = 1; $position -le $views.Count; $position++) {
        Send-Keys $Session "%$position"
        Save-ArchivedSwitch $Session "view-$position-off" $false 2 0
        Send-Keys $Session '%a'
        Save-ArchivedSwitch $Session "view-$position-on" $true 4 2
        if ($position -eq 1) {
            Invoke-PaletteCommand $Session 'Toggle archived chats in this view' 'palette-switch'
            Save-ArchivedSwitch $Session palette-off $false 2 0
            Send-Keys $Session '%a'
            Save-ArchivedSwitch $Session palette-on $true 4 2
        }
        Send-Keys $Session '^1'
        $null = Wait-Until { (Read-Control $Session status).selected.name -like '*row 0' } 'normal read row selected'
        $id = (Read-Control $Session status).selected.id
        Send-Keys $Session '^e'
        Save-ArchivedSwitch $Session "view-$position-archived" $true 4 3
        Assert-That ((Read-Control $Session status).selected.id -eq $id -and (Read-Control $Session status).selected.archived) 'Mixed archive moved the selected row'
        Send-Keys $Session '^e'
        Save-ArchivedSwitch $Session "view-$position-unarchived" $true 4 2
        if ($position -ne 1) {
            Send-Keys $Session '%a'
            Save-ArchivedSwitch $Session "view-$position-disabled" $false 2 0
        }
    }
    Send-Keys $Session '%1'
    Save-ArchivedSwitch $Session account-one-kept $true 4 2
    Send-Keys $Session '%2'
    Save-ArchivedSwitch $Session account-two-off $false 2 0
    Send-Keys $Session '%i'
    Save-ArchivedSwitch $Session inbox-kept $true 10 5
    Invoke-PaletteCommand $Session 'Show archived chats'
    $null = Wait-Until { (Read-Control $Session status).show_archived -and (Read-Control $Session status).chat_count -eq 10 } 'archived-only command unchanged'
    Save-Screen $Session archived-only
    Invoke-PaletteCommand $Session 'Show inbox chats'
    Save-ArchivedSwitch $Session inbox-return $true 10 5
    $old = Get-App $Session
    $oldPid = $Session.pid
    $oldTicks = $Session.startTicks
    Invoke-PaletteCommand $Session 'Quit Messages'
    $null = Wait-Until { $old.Refresh(); $old.HasExited } 'closed for same-profile restart'
    $Start.Environment['WAZIG_VERIFY_RESTART'] = $Session.id
    $app = [Diagnostics.Process]::Start($Start)
    $Session.pid = $app.Id
    $Session.startTicks = $app.StartTime.ToUniversalTime().Ticks.ToString()
    $Session | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence 'session.json')
    @{ old_pid = $oldPid; old_start = $oldTicks; new_pid = $Session.pid; new_start = $Session.startTicks; root = $Session.root; id = $Session.id; sha256 = $Session.sha256 } |
        ConvertTo-Json | Set-Content (Join-Path $Session.evidence 'show-archived-restart.json')
    $null = Wait-Until { $app.Refresh(); $app.MainWindowHandle -ne [IntPtr]::Zero } 'restarted fixture window'
    [VerifyWindow]::ShowWindow($app.MainWindowHandle, 3) | Out-Null
    Send-Keys $Session '%i'
    Save-ArchivedSwitch $Session restart-inbox $true 10 5
    Send-Keys $Session '%1'
    Save-ArchivedSwitch $Session restart-one $true 4 2
    Send-Keys $Session '%2'
    Save-ArchivedSwitch $Session restart-two $false 2 0
    Send-Keys $Session '%i'
    Save-ArchivedSwitch $Session after $true 10 5
    Invoke-Doctor $Session | Out-Null
    Hub-Pass $Session show-archived-all | Out-Null
    return $app
}
