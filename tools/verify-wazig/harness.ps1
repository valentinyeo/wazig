$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class VerifyWindow {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr dialog, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode)]
    public static extern IntPtr WriteText(IntPtr window, uint message, UIntPtr wparam, string text, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode)]
    public static extern IntPtr ReadText(IntPtr window, uint message, UIntPtr capacity, StringBuilder text, uint flags, uint timeout, out UIntPtr length);
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode)]
    public static extern IntPtr ReadCount(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr count);
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW")]
    public static extern IntPtr ReadListMetric(IntPtr window, uint message, UIntPtr index, IntPtr unused, uint flags, uint timeout, out UIntPtr value);
}
'@

function Assert-That($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Wait-Until([scriptblock]$Check, [string]$Description, [int]$Seconds = 20) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $value = & $Check
        if ($value) { return $value }
        [System.Threading.Thread]::Sleep(100)
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $Description"
}

function Read-Session([string]$Evidence) {
    Get-Content (Join-Path $Evidence 'session.json') -Raw | ConvertFrom-Json
}

function Get-App($Session) {
    $app = Get-Process -Id $Session.pid -ErrorAction Stop
    Assert-That ($app.StartTime.ToUniversalTime().Ticks.ToString() -eq $Session.startTicks) 'PID was reused'
    Assert-That ($app.Path -eq $Session.exe) 'Wrong executable path'
    Assert-That ((Get-FileHash $app.Path).Hash -eq $Session.sha256) 'Executable changed after launch'
    return $app
}

function Read-Control($Session, [string]$Command, [string[]]$Arguments = @(), [int]$TimeoutMilliseconds = 15000) {
    $start = [Diagnostics.ProcessStartInfo]::new($Session.ctl)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add($Command)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.Environment['USERNAME'] = $Session.username
    $child = [Diagnostics.Process]::Start($start)
    try {
        $output = $child.StandardOutput.ReadToEndAsync()
        $errorOutput = $child.StandardError.ReadToEndAsync()
        Assert-That ($child.WaitForExit($TimeoutMilliseconds)) "Read-only control client timed out after $TimeoutMilliseconds ms: $Command"
        $text = $output.GetAwaiter().GetResult()
        $errors = $errorOutput.GetAwaiter().GetResult()
        Assert-That ($child.ExitCode -eq 0) "Read-only control failed: $errors"
        $response = $text | ConvertFrom-Json
        Assert-That $response.ok 'Control response is not OK'
        return $response.result
    } finally {
        if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
        $child.Dispose()
    }
}

function Get-Window($Session) {
    $null = Get-App $Session
    $condition = [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$Session.pid),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ClassNameProperty, 'MessagesZig')
    )
    $window = [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $condition)
    Assert-That ($null -ne $window) 'App window is not up'
    Assert-That ($window.Current.ProcessId -eq $Session.pid) 'UI Automation found another process'
    Assert-That ($window.Current.ClassName -eq 'MessagesZig') 'Wrong window class'
    Assert-That ($window.Current.Name -cmatch '^(?:.+ - )?Wazig v0\.0\.526$') 'Wrong build title'
    return $window
}

function Get-Edit($Window, [string]$Id) {
    $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $edit = $Window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
    Assert-That ($null -ne $edit) "Missing stable edit AutomationId=$Id"
    return $edit
}

function Read-EditText([IntPtr]$Handle) {
    $text = [Text.StringBuilder]::new(65537)
    $length = [UIntPtr]::Zero
    $ok = [VerifyWindow]::ReadText($Handle, 13, [UIntPtr]65537, $text, 2, 2000, [ref]$length)
    Assert-That ($ok -ne [IntPtr]::Zero) 'Read-only WM_GETTEXT timed out'
    return $text.ToString()
}

function Read-Edit($Edit) {
    $handle = [IntPtr]$Edit.Current.NativeWindowHandle
    Assert-That ($handle -ne [IntPtr]::Zero -and $Edit.Current.ClassName -eq 'RICHEDIT50W') 'Expected a DirectWrite RichEdit host'
    $valueMismatch = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $text = Read-EditText $handle
        $value = $Edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
        $after = Read-EditText $handle
        if ($text -ceq $after) {
            $value = $value.Replace("`r`n", "`n").Replace("`r", "`n")
            $valueMismatch = $value -ne $text
            if (-not $valueMismatch) { return $text }
        }
        if ($attempt -lt 19) { [System.Threading.Thread]::Sleep(50) }
    }
    if ($valueMismatch) { throw 'Screen-reader value differs from edit text' }
    throw 'Edit text never settled'
}

function Read-ListCount($List) {
    $handle = [IntPtr]$List.Current.NativeWindowHandle
    Assert-That ($handle -ne [IntPtr]::Zero -and $List.Current.ClassName -eq 'LISTBOX') 'Expected a native listbox'
    $count = [UIntPtr]::Zero
    $ok = [VerifyWindow]::ReadCount($handle, 0x018B, [UIntPtr]::Zero, [IntPtr]::Zero, 2, 2000, [ref]$count)
    Assert-That ($ok -ne [IntPtr]::Zero) 'Read-only LB_GETCOUNT timed out'
    Assert-That ($count.ToUInt64() -le [int]::MaxValue) 'Read-only LB_GETCOUNT failed'
    return [int]$count.ToUInt64()
}

function Read-ListLabels($List) {
    $count = Read-ListCount $List
    Assert-That ($count -le 512) 'Read-only list label count exceeds limit'
    $handle = [IntPtr]$List.Current.NativeWindowHandle
    for ($index = 0; $index -lt $count; $index++) {
        $length = [UIntPtr]::Zero
        $ok = [VerifyWindow]::ReadCount($handle, 0x018A, [UIntPtr]$index, [IntPtr]::Zero, 2, 2000, [ref]$length)
        Assert-That ($ok -ne [IntPtr]::Zero) 'Read-only LB_GETTEXTLEN timed out'
        Assert-That ($length.ToUInt64() -le 63) 'Read-only LB_GETTEXTLEN failed or label exceeds limit'
        $text = [Text.StringBuilder]::new(64)
        $copied = [UIntPtr]::Zero
        $ok = [VerifyWindow]::ReadText($handle, 0x0189, [UIntPtr]$index, $text, 2, 2000, [ref]$copied)
        Assert-That ($ok -ne [IntPtr]::Zero) 'Read-only LB_GETTEXT timed out'
        Assert-That ($copied.ToUInt64() -eq $length.ToUInt64() -and $text.Length -eq $length.ToUInt64()) 'Read-only LB_GETTEXT failed or label changed'
        $text.ToString()
    }
    Assert-That ((Read-ListCount $List) -eq $count) 'List changed while reading labels'
}

function Send-Keys($Session, [string]$Keys) {
    $app = Get-App $Session
    $null = Wait-Until {
        $foreground = [VerifyWindow]::GetForegroundWindow()
        $ownerPid = [uint32]0
        if ($foreground -ne [IntPtr]::Zero) {
            [VerifyWindow]::GetWindowThreadProcessId($foreground, [ref]$ownerPid) | Out-Null
        }
        if ($foreground -eq [IntPtr]::Zero -or $ownerPid -ne $Session.pid) {
            $app.Refresh()
            [VerifyWindow]::SetForegroundWindow($app.MainWindowHandle) | Out-Null
            return $false
        }
        return $true
    } 'app foreground window before keyboard input'
    $foreground = [VerifyWindow]::GetForegroundWindow()
    $ownerPid = [uint32]0
    if ($foreground -ne [IntPtr]::Zero) {
        [VerifyWindow]::GetWindowThreadProcessId($foreground, [ref]$ownerPid) | Out-Null
    }
    Assert-That ($foreground -ne [IntPtr]::Zero -and $ownerPid -eq $Session.pid) 'Refusing keyboard input to another app'
    [System.Windows.Forms.SendKeys]::SendWait($Keys)
    Add-Content (Join-Path $Session.evidence 'actions.log') "keys: $Keys"
}

function Get-PaletteWindow($Session) {
    $owner = Get-Window $Session
    return Wait-Until {
        $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ClassNameProperty, 'MessagesPalette')
        $windows = $owner.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
        foreach ($window in $windows) { if ($window.Current.ProcessId -eq $Session.pid) { return $window } }
    } 'owned command palette'
}

function Invoke-PaletteCommand($Session, [string]$Command, [string]$Capture = '') {
    Send-Keys $Session '^k'
    $palette = Get-PaletteWindow $Session
    $edit = Get-Edit $palette '1064'
    Send-Keys $Session $Command
    $null = Wait-Until { (Read-Edit $edit) -eq $Command } 'palette query'
    if ($Capture) {
        Save-Screen $Session $Capture
        "MessagesPalette | $($palette.Current.ProcessId) | $(Read-Edit $edit)" | Set-Content (Join-Path $Session.evidence "$Capture.palette.uia.txt")
    }
    Send-Keys $Session '{ENTER}'
}

function Save-Screen($Session, [string]$Name) {
    $window = Get-Window $Session
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $image = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    $graphics = [Drawing.Graphics]::FromImage($image)
    try {
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
        $image.Save((Join-Path $Session.evidence "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $image.Dispose()
    }
    $elements = $window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    $tree = @("$($window.Current.ClassName) | $($window.Current.Name)")
    foreach ($element in $elements) {
        $tree += "$($element.Current.AutomationId) | $($element.Current.ClassName) | $($element.Current.Name)"
    }
    $tree | Set-Content (Join-Path $Session.evidence "$Name.uia.txt")
    $state = Read-Control $Session status
    $state | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence "$Name.state.json")
    if ($Session.feature -in @('show-archived', 'archive', 'archive-bulk', 'hub-archive', 'palette-archived', 'slack-sort', 'slack-archive', 'slack-threads', 'workspace-icons', 'signal', 'telegram', 'notrap', 'passage-copy', 'reactions')) {
        $arguments = if ($state.show_archived) { @('--archived') } else { @() }
        Read-Control $Session chats -Arguments $arguments | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence "$Name.chats.json")
    }
}

function Invoke-Doctor($Session) {
    $window = Get-Window $Session
    $search = Get-Edit $window '1008'
    $compose = Get-Edit $window '1032'
    Assert-That $compose.Current.IsEnabled 'Fixture chat is not usable'
    $null = Read-Edit $search
    if ($Session.feature -in @('whatsapp-hub', 'hub')) {
        $null = Wait-Until { (Read-Control $Session status).chat_count -eq $(if ($Session.feature -eq 'hub') { 3 } else { 2 }) } 'hub baseline'
    }
    if ($Session.feature -eq 'views') {
        $null = Wait-Until { (Read-Control $Session status).view_order.Count -eq 6 } 'account views baseline'
    }
    $status = Read-Control $Session status
    Assert-That ($status.version -eq '0.0.526') 'Wrong control build'
    $label = if ($status.current_view.inbox) { 'Combined inbox' } else { $status.current_view.label }
    Assert-That ((Get-Window $Session).Current.Name -ceq "$label - Wazig v$($status.version)") 'Window title does not match the active inbox'
    Assert-That ($status.sync -eq 'stopped' -and -not $status.slack_connected) 'Provider unexpectedly connected'
    Assert-That ($status.pending_sends -eq 0 -and $status.pending_archives -eq 0) 'Unexpected pending writes'
    $status | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence 'doctor.json')
    Write-Output 'DOCTOR PASSED: build, owned window, usable fixture and readable UI Automation edits'
}

function Start-FakeBridge([string]$Evidence, [string]$Root, [string]$Mode) {
    $registry = Get-Content (Join-Path $PSScriptRoot 'journeys.json') -Raw | ConvertFrom-Json
    Assert-That ($Mode -in @($registry.journeys.hub | Where-Object { $_ })) "Unknown fake bridge mode: $Mode"
    $portFile = Join-Path $Root 'bridge-port.txt'
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command python).Source)
    $start.UseShellExecute = $false
    $script = if ($Mode -eq 'legacy') { 'fake-wa-bridge.py' } else { 'fake-hub.py' }
    $start.ArgumentList.Add((Join-Path $PSScriptRoot $script))
    if ($Mode -ne 'legacy') { $start.ArgumentList.Add("--$Mode") }
    $start.ArgumentList.Add('--port-file')
    $start.ArgumentList.Add($portFile)
    $start.ArgumentList.Add('--log')
    $start.ArgumentList.Add((Join-Path $Evidence 'bridge-requests.jsonl'))
    $process = [Diagnostics.Process]::Start($start)
    try {
        $null = Wait-Until { if ($process.HasExited) { throw 'Fake bridge exited' }; (Test-Path $portFile) -and (Get-Item $portFile).Length -gt 0 } 'fake bridge listening'
        $port = [int](Get-Content $portFile -Raw)
        return @{ process = $process; url = "http://127.0.0.1:$port" }
    } catch {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        throw
    }
}

function Read-BridgeRequests($Session) {
    $path = Join-Path $Session.evidence 'bridge-requests.jsonl'
    if (-not (Test-Path $path)) { return @() }
    return @(Get-Content $path | Where-Object { $_.EndsWith('}') } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Hub-Pass($Session, [string]$Gate) {
    $line = "$($Session.feature) $Gate PASS"
    Write-Output $line
    Add-Content (Join-Path $Session.evidence 'hub-proof.log') $line
}

function Invoke-WhatsAppHubJourney($Session, [string]$Messages) {
    $state = Read-Control $Session status
    $unified = $Session.feature -eq 'hub'
    $rows = (Read-Control $Session chats).chats
    $alpha = if ($unified) { 'fixture-alpha' } else { ($rows | Where-Object name -eq 'Verification Alpha').id }
    $beta = if ($unified) { 'fixture-beta' } else { ($rows | Where-Object name -eq 'Verification Beta').id }
    $provider = if ($unified) { 'slack' } else { 'whatsapp' }
    Assert-That ($state.chat_count -eq $(if ($unified) { 3 } else { 2 }) -and $state.selected.name -eq 'Verification Alpha' -and $state.selected.id -eq $alpha -and $state.selected.provider -eq $provider) 'Hub chats did not reach the sidebar'
    $requests = @(Read-BridgeRequests $Session)
    $listPaths = if ($unified) { @('/v1/chats?') } else { @('/v1/accounts', '/v1/chats?') }
    foreach ($path in $listPaths) {
        Assert-That (@($requests | Where-Object { $_.path.StartsWith($path) -and $_.status -eq 200 }).Count -gt 0) "Missing hub list request: $path"
    }
    Hub-Pass $Session chats
    if ($unified) {
        foreach ($mode in @('views', 'unfiltered-views')) {
            $views = @{}
            foreach ($view in @('slack', 'whatsapp', 'all')) {
                $arguments = @('--json', '--messenger', $view)
                if ($mode -eq 'unfiltered-views') { $arguments += '--all' }
                $views[$view] = Read-Control $Session chats -Arguments $arguments
            }
            $views | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence "provider-$mode.json")
        }
    }
    if (-not $unified) {
        $null = Wait-Until { @(Read-BridgeRequests $Session | Where-Object { $_.path -eq '/v1/send' -and $_.body.client_id -eq '53200000000000000000000000000001' }).Count -eq 1 } 'foreign outbox startup send'
        $adopted = @(Read-BridgeRequests $Session | Where-Object { $_.path -eq '/v1/send' -and $_.body.client_id -eq '53200000000000000000000000000001' })
        Assert-That ($adopted.Count -eq 1 -and $adopted[0].status -eq 200 -and $adopted[0].accepted -eq $true) 'Adopted send was not delivered exactly once'
        Assert-That ($adopted[0].body.account -eq 'personal' -and $adopted[0].body.chat -eq $alpha -and $adopted[0].body.reply_to -eq 'BASELINE') 'Adopted send kept foreign identity'
        Assert-That ([string]::IsNullOrEmpty((Get-Content (Join-Path $Messages 'hub-1111111111111111-outbox.jsonl') -Raw))) 'Adopted line remains in foreign outbox'
        Hub-Pass $Session foreign-outbox-startup
    }
    $null = Wait-Until { @((Read-Control $Session messages).messages | Where-Object id -eq 'BASELINE').Count -eq 1 } 'hub history visible'
    Assert-That (@($rows | Where-Object { $_.id -eq $beta -and $_.last_message_time }).Count -eq 1) 'Beta must have a last message timestamp'
    $requests = @(Read-BridgeRequests $Session)
    Assert-That (@($requests | Where-Object { $null -ne $_.history_request }).Count -eq 0) 'Beta history was requested before the first switch'
    $requests | ConvertTo-Json -Depth 12 -AsArray | Set-Content (Join-Path $Session.evidence 'before-beta.requests.json')
    Send-Keys $Session '^{TAB}'
    $switchTimer = [Diagnostics.Stopwatch]::StartNew()
    $selected = (Read-Control $Session status -TimeoutMilliseconds 1000).selected
    Assert-That ($selected.id -eq $beta -and $selected.name -eq 'Verification Beta') 'Keyboard did not select Beta'
    $remaining = 1000 - [int][Math]::Ceiling($switchTimer.Elapsed.TotalMilliseconds)
    Assert-That ($remaining -gt 0) 'Beta selection exceeded one second'
    $shown = Read-Control $Session messages -TimeoutMilliseconds $remaining
    $elapsed = $switchTimer.Elapsed.TotalMilliseconds
    @{ elapsed_ms = $elapsed; selected = $selected } | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence 'beta-switch.json')
    $shown | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence 'beta-empty.messages.json')
    Assert-That ($elapsed -le 1000) 'Beta messages response exceeded one second'
    foreach ($field in @('id', 'provider', 'account')) {
        Assert-That ($shown.chat.$field -eq $selected.$field) "Shown Beta $field differs from selection"
    }
    Assert-That ($shown.messages.Count -eq 0) 'Uncached Beta pane retained messages before history arrived'
    Save-Screen $Session beta-empty
    $null = Wait-Until {
        $shown = Read-Control $Session messages
        (Read-Control $Session status).selected.id -eq $beta -and $shown.chat.id -eq $beta -and $shown.messages.Count -eq 1 -and $shown.messages[0].id -eq 'BASELINE_BETA' -and $shown.messages[0].text -eq 'Fixture Beta history'
    } 'hub Beta selected with only Beta history'
    $requests = @(Read-BridgeRequests $Session)
    Assert-That (@($requests | Where-Object { $_.history_request -eq 1 -and $_.status -eq 200 -and $_.history_delay_ms -ge 3000 }).Count -eq 1) 'First Beta history response was not delayed three seconds'
    Read-Control $Session messages | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence 'beta.messages.json')
    Save-Screen $Session beta
    Send-Keys $Session '^+{TAB}'
    $null = Wait-Until {
        $shown = Read-Control $Session messages
        (Read-Control $Session status).selected.id -eq $alpha -and $shown.chat.id -eq $alpha -and @($shown.messages | Where-Object id -eq 'BASELINE').Count -eq 1 -and @($shown.messages | Where-Object id -eq 'BASELINE_BETA').Count -eq 0
    } 'hub Alpha selected with only Alpha history'
    Hub-Pass $Session chat-switch
    if ($unified) {
        $sidebar = @{}
        foreach ($view in @('whatsapp', 'slack', 'all')) {
            $keys = switch ($view) { 'whatsapp' { '%1' } 'slack' { '%2' } 'all' { '%0' } }
            Send-Keys $Session $keys
            $null = Wait-Until { (Read-Control $Session status).view -eq $view } "sidebar $view view"
            $sidebar[$view] = @{
                state = Read-Control $Session status
                chats = Read-Control $Session chats -Arguments @('--json')
            }
            Save-Screen $Session "provider-$view"
        }
        $sidebar | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence 'provider-sidebar.json')
        & python (Join-Path $PSScriptRoot 'check-hub-views.py') $Session.evidence
        Assert-That ($LASTEXITCODE -eq 0) 'Hub provider views failed'
        Assert-That ((Read-Control $Session status).selected.id -eq $alpha) 'All view did not restore Alpha'
        $null = Wait-Until {
            $shown = Read-Control $Session messages
            $shown.chat.id -eq $alpha -and @($shown.messages | Where-Object id -eq 'BASELINE').Count -eq 1 -and @($shown.messages | Where-Object id -eq 'BASELINE_BETA').Count -eq 0
        } 'Alpha history restored after provider views'
        Hub-Pass $Session provider-views
        $mixedRow = @((Read-Control $Session chats -Arguments @('--json', '--messenger', 'whatsapp')).chats | Where-Object name -eq 'Verification Mixed')
        Assert-That ($mixedRow.Count -eq 1 -and $mixedRow[0].id -eq '15550000005@s.whatsapp.net') 'Mixed WhatsApp chat missing from the list'
        $alphaRow = @($rows | Where-Object id -eq $alpha)[0]
        $null = Read-Control $Session select -Arguments @($mixedRow[0].id, '--provider', $mixedRow[0].provider, '--account', $mixedRow[0].account)
        $expectedTexts = @('Mixed phone first', 'Mixed lid first', 'Mixed phone second', 'Mixed lid second')
        $null = Wait-Until {
            $shown = Read-Control $Session messages
            (Read-Control $Session status).selected.id -eq $mixedRow[0].id -and $shown.chat.id -eq $mixedRow[0].id -and @($expectedTexts | Where-Object { $_ -in @($shown.messages.text) }).Count -eq $expectedTexts.Count
        } 'mixed phone and lid page shown'
        $shown = Read-Control $Session messages
        $shown | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence 'mixed-lid.messages.json')
        Save-Screen $Session mixed-lid
        Assert-That (@($shown.messages | Where-Object { $_.text -in $expectedTexts }).Count -eq $expectedTexts.Count) 'Mixed page lost messages'
        $mixedReads = @(Read-BridgeRequests $Session | Where-Object { $_.wire_path.StartsWith('/v1/wazig/messages?') -and $_.wire_path.Contains('15550000005') -and $_.status -eq 200 })
        Assert-That ($mixedReads.Count -gt 0) 'Mixed chat page was never served'
        Assert-That (-not ((Get-Content (Join-Path $Messages 'launch-log.txt') -Raw).Contains('WrongChat'))) 'Launch log reports WrongChat for the mixed page'
        Assert-That ($shown.messages.Count -eq 80) 'Mixed chat did not open with its newest 80 messages'
        $null = Wait-Until {
            Send-Keys $Session '{PGUP}'
            @(Read-BridgeRequests $Session | Where-Object { [string]$_.mixed_before -ne '' -and $_.mixed_count -eq 0 -and $_.status -eq 200 }).Count -gt 0
        } 'Mixed chat scrolled up to its first message' -Seconds 120
        $paged = Read-Control $Session messages
        $paged | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence 'mixed-paged.messages.json')
        Save-Screen $Session mixed-paged
        $pagedIds = @($paged.messages | ForEach-Object { $_.id })
        Assert-That ($paged.chat.id -eq $mixedRow[0].id -and $pagedIds.Count -eq 250) "Scrolled chat holds $($pagedIds.Count) of 250 messages"
        Assert-That (@($pagedIds | Select-Object -Unique).Count -eq 250) 'Scrolled chat shows a message twice'
        for ($position = 0; $position -lt 250; $position++) {
            Assert-That ($pagedIds[$position] -eq "MIXED-$(250 - $position)") "Scrolled chat is out of order at position $position"
        }
        $olderPages = @(Read-BridgeRequests $Session | Where-Object { [string]$_.mixed_before -ne '' -and $_.status -eq 200 })
        $olderPages | ConvertTo-Json -Depth 12 -AsArray | Set-Content (Join-Path $Session.evidence 'mixed-older.requests.json')
        Assert-That ($olderPages.Count -ge 4 -and @($olderPages | Where-Object mixed_count -eq 0).Count -eq 1 -and $olderPages[-1].mixed_count -eq 0) 'Older pages did not end with exactly one empty page'
        Send-Keys $Session '{PGUP}{PGUP}{PGUP}'
        Hub-Pass $Session mixed-older-pages
        Send-Keys $Session '^k'
        Send-Keys $Session 'Archive selected chat'
        Send-Keys $Session '{ENTER}'
        $null = Wait-Until { @(Read-BridgeRequests $Session | Where-Object { $_.path -eq '/v1/archive' -and $_.body.archived -eq $true -and $_.body.chat -eq $mixedRow[0].id -and $_.status -eq 200 }).Count -gt 0 } 'mixed chat archive'
        $null = Wait-Until { (Read-Control $Session status).chat_count -eq 2 -and (Read-Control $Session status).pending_archives -eq 0 } 'mixed chat removed'
        Hub-Pass $Session mixed-lid-page
        $null = Read-Control $Session select -Arguments @($alphaRow.id, '--provider', $alphaRow.provider, '--account', $alphaRow.account)
        $null = Wait-Until {
            $shown = Read-Control $Session messages
            (Read-Control $Session status).selected.id -eq $alpha -and $shown.chat.id -eq $alpha -and @($shown.messages | Where-Object id -eq 'BASELINE').Count -eq 1
        } 'Alpha reselected after mixed page'
    }
    Read-Control $Session messages | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence 'history.messages.json')
    Save-Screen $Session history
    Hub-Pass $Session history
    $null = Wait-Until { @(Read-BridgeRequests $Session | Where-Object { $_.path -eq '/v1/mark-read' -and $_.body.chat -eq $alpha -and $_.status -eq 200 }).Count -gt 0 } 'hub mark-read'
    Hub-Pass $Session mark-read
    $null = Wait-Until { @(Read-BridgeRequests $Session | Where-Object { $_.path -eq '/v1/events' -and $_.last_event_id -eq '1' }).Count -gt 0 } 'SSE baseline resume'
    $headers = @{ Authorization = 'Bearer fixture-key-not-a-secret' }
    Invoke-RestMethod "$($Session.bridge_url)/fixture/live" -Method Post -Headers $headers -Body '{}' -ContentType 'application/json' | Out-Null
    $null = Wait-Until { @((Read-Control $Session messages).messages | Where-Object id -eq 'LIVE').Count -eq 1 } 'live SSE message visible'
    Read-Control $Session messages | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence 'live.messages.json')
    Save-Screen $Session live
    $null = Wait-Until { @(Read-BridgeRequests $Session | Where-Object { $_.path -eq '/v1/events' -and $_.last_event_id -eq '2' }).Count -gt 0 } 'SSE live resume'
    Hub-Pass $Session live-sse-replay
    Send-Keys $Session '^k'
    Send-Keys $Session 'Compose message'
    Send-Keys $Session '{ENTER}'
    Send-Keys $Session 'Fixture outgoing'
    Send-Keys $Session '{ENTER}'
    $null = Wait-Until { @(Read-BridgeRequests $Session | Where-Object { $_.path -eq '/v1/send' -and $_.duplicate -eq $true -and $_.status -eq 200 }).Count -eq 1 } 'deduplicated hub retry'
    $sends = @(Read-BridgeRequests $Session | Where-Object { $_.path -eq '/v1/send' -and $_.body.client_id -ne '53200000000000000000000000000001' })
    Assert-That ($sends.Count -ge 2 -and @($sends.body.client_id | Select-Object -Unique).Count -eq 1) 'Send retry changed client_id'
    Assert-That (@($sends | Where-Object accepted -eq $true).Count -eq 1) 'Send delivered more than once'
    Assert-That ($sends[0].body.client_id -match '^[a-f0-9]{32}$') 'Send did not use the outbox id'
    $null = Wait-Until { (Read-Control $Session status).pending_sends -eq 0 } 'outbox acknowledged'
    Hub-Pass $Session send-client-id-dedupe
    $null = Wait-Until {
        $media = @(Read-BridgeRequests $Session | Where-Object { $_.path.StartsWith('/v1/media/') })
        @($media | Where-Object status -eq 202).Count -gt 0 -and @($media | Where-Object status -eq 200).Count -gt 0
    } 'pending then ready media'
    $null = Wait-Until { @(Get-ChildItem (Join-Path $Messages 'hub-media') -Filter '*.bin' | Where-Object Length -gt 0).Count -gt 0 } 'durable media cache'
    $ready = @(Read-BridgeRequests $Session | Where-Object { $_.path.StartsWith('/v1/media/') -and $_.status -eq 200 })[0]
    $cached = @(Get-ChildItem (Join-Path $Messages 'hub-media') -Filter '*.bin' | Where-Object { (Get-FileHash $_.FullName).Hash.ToLowerInvariant() -eq $ready.sha256 })
    Assert-That ($cached.Count -gt 0) 'Downloaded media bytes differ from bridge response'
    Hub-Pass $Session media-202-ready-cache
    Save-Screen $Session sent
    if ($unified) {
        Send-Keys $Session '^{TAB}'
        $null = Wait-Until { (Read-Control $Session status).selected.id -eq $beta } 'WhatsApp archive target'
    }
    $archiveTarget = if ($unified) { $beta } else { $alpha }
    Send-Keys $Session '^k'
    Send-Keys $Session 'Archive selected chat'
    Send-Keys $Session '{ENTER}'
    $null = Wait-Until { @(Read-BridgeRequests $Session | Where-Object { $_.path -eq '/v1/archive' -and $_.body.archived -eq $true -and $_.body.chat -eq $archiveTarget -and $_.status -eq 200 }).Count -gt 0 } 'hub archive'
    $null = Wait-Until { (Read-Control $Session status).chat_count -eq 1 -and (Read-Control $Session status).pending_archives -eq 0 } 'archived chat removed'
    Hub-Pass $Session archive
    Save-Screen $Session after
    $requests = @(Read-BridgeRequests $Session | Where-Object { $_.method -ne 'SSE' })
    Assert-That (@($requests | Where-Object authorized -ne $true).Count -eq 0) 'Unauthenticated hub request'
    if ($unified) {
        Assert-That (@($requests | Where-Object { $_.wire_path -ne '/fixture/live' -and -not $_.wire_path.StartsWith('/v1/wazig/') }).Count -eq 0) 'Request bypassed unified hub'
        Assert-That (@($requests | Where-Object { $_.wire_path.Contains('account=') }).Count -eq 0) 'Source account leaked into hub query'
        Assert-That (@($requests | Where-Object { [string]$_.mixed_before -ne '' -and $_.status -eq 200 }).Count -eq $olderPages.Count) 'Older pages were requested again after an empty page'
        $final = Read-Control $Session status
        Assert-That ($final.selected.provider -eq 'slack') 'Hub lost source network identity'
    }
    $backend = if ($unified) { 'message backend:' } else { 'whatsapp backend:' }
    $launch = Get-Content (Join-Path $Messages 'launch-log.txt')
    Assert-That (@($launch | Where-Object { $_ -match $backend }).Count -eq 1) 'Backend was logged more than once'
    Assert-That (@($launch | Where-Object { $_ -match "$backend hub`$" }).Count -eq 1) 'Hub was not selected'
    Assert-That (-not (($launch -join "`n").Contains('WrongChat'))) 'Launch log reports WrongChat'
    Assert-That (-not (($launch -join "`n").Contains('fixture-key-not-a-secret'))) 'Launch log leaked key'
    $preferences = "HKCU:\Software\MessagesVerification\$($Session.id)\Software\Messages"
    $registry = Get-Item $preferences
    $secret = if ($unified) { 'HubToken' } else { 'WaBridgeKey' }
    Assert-That ($registry.GetValueKind($secret) -eq [Microsoft.Win32.RegistryValueKind]::Binary) 'Bridge key is not DPAPI storage'
    Hub-Pass $Session auth-dpapi-backend
}

function Assert-ComposerLayout($Session, [string]$Name, [int]$Lines, $Baseline = $null) {
    $state = Read-Control $Session status
    $layout = $state.composer
    Assert-That ($null -ne $layout -and $layout.lines -eq $Lines) "composer-one-box $Name wrong line count"
    $box = $layout.box
    Assert-That ($box.right -gt $box.left -and $box.bottom -gt $box.top) "composer-one-box $Name empty box"
    $names = @('attach', 'text', 'mic', 'dictate', 'emoji', 'send')
    $ids = @('1136', '1032', '1104', '1056', '1080', '1040')
    Assert-That ($layout.controls.Count -eq $names.Count) "composer-one-box $Name missing controls"
    $window = Get-Window $Session
    $handle = [IntPtr]$window.Current.NativeWindowHandle
    $client = [VerifyWindow+Rect]::new()
    $origin = [VerifyWindow+Point]::new()
    Assert-That ([VerifyWindow]::GetClientRect($handle, [ref]$client)) 'Cannot measure native client area'
    Assert-That ([VerifyWindow]::ClientToScreen($handle, [ref]$origin)) 'Cannot measure native client origin'
    $dpi = [VerifyWindow]::GetDpiForWindow($handle)
    Assert-That ($dpi -gt 0) 'Cannot measure window DPI'
    $bottomInset = [Math]::Floor((11 * $dpi + 48) / 96)
    $iconInset = [Math]::Floor((4 * $dpi + 48) / 96)
    $boxBottom = $client.Bottom - $bottomInset
    Assert-That ($box.bottom -eq $boxBottom) "composer-one-box $Name box not anchored to native client bottom"
    $offsetX = $origin.X
    $offsetY = $origin.Y
    for ($i = 0; $i -lt $names.Count; $i++) {
        $rect = $layout.controls[$i]
        Assert-That ($rect.name -eq $names[$i]) "composer-one-box $Name unexpected control order"
        Assert-That ($rect.right -gt $rect.left -and $rect.bottom -gt $rect.top) "composer-one-box $Name empty $($rect.name)"
        Assert-That ($rect.left -ge $box.left -and $rect.right -le $box.right -and $rect.top -ge $box.top -and $rect.bottom -le $box.bottom) "composer-one-box $Name $($rect.name) outside box"
        $element = Get-Edit $window $ids[$i]
        Assert-That (-not $element.Current.IsOffscreen) "composer-one-box $Name hidden $($rect.name)"
        if ($rect.name -ne 'text') {
            Assert-That (-not [string]::IsNullOrWhiteSpace($element.Current.Name)) "composer-one-box $Name unnamed icon"
            Assert-That ($rect.bottom -eq $box.bottom - $iconInset) "composer-one-box $Name icon not anchored to box bottom"
        }
        $bounds = $element.Current.BoundingRectangle
        if ($rect.name -ne 'text') {
            Assert-That ([Math]::Abs($bounds.Bottom - ($origin.Y + $boxBottom - $iconInset)) -le 1) "composer-one-box $Name UIA icon not anchored to native bottom"
        }
        Assert-That ([Math]::Abs($bounds.Left - $offsetX - $rect.left) -le 1 -and [Math]::Abs($bounds.Top - $offsetY - $rect.top) -le 1 -and [Math]::Abs($bounds.Right - $offsetX - $rect.right) -le 1 -and [Math]::Abs($bounds.Bottom - $offsetY - $rect.bottom) -le 1) "composer-one-box $Name UIA mismatch $($rect.name)"
        for ($j = $i + 1; $j -lt $names.Count; $j++) {
            $other = $layout.controls[$j]
            Assert-That ($rect.right -le $other.left -or $other.right -le $rect.left -or $rect.bottom -le $other.top -or $other.bottom -le $rect.top) "composer-one-box $Name overlapping controls"
        }
        if ($null -ne $Baseline -and $rect.name -ne 'text') {
            $initial = $Baseline.controls[$i]
            Assert-That ($rect.left -eq $initial.left -and $rect.right -eq $initial.right -and $rect.top -eq $initial.top -and $rect.bottom -eq $initial.bottom) "composer-one-box $Name icon moved while growing"
        }
    }
    if ($null -ne $Baseline) {
        Assert-That ($box.bottom -eq $Baseline.box.bottom -and $box.top -lt $Baseline.box.top) "composer-one-box $Name box did not grow upwards"
    }
    $layout | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Session.evidence "$Name.layout.json")
    Save-Screen $Session $Name
    $message = "composer-one-box $Name lines=$Lines theme=$($state.theme) PASS"
    Add-Content (Join-Path $Session.evidence 'composer-one-box.log') $message
    Write-Host $message
    return $layout
}

function Invoke-WorkspaceIconsJourney($Session) {
    Send-Keys $Session '%0'
    $null = Wait-Until { (Read-Control $Session status).view -eq 'all' } 'All networks sidebar'
    $expected = @('slack:fixture-amber:channel-alpha', 'slack:fixture-cobalt:channel-beta', 'whatsapp:fixture:contact-delta', 'slack:fixture-empty:channel-gamma', 'signal:fixture-contact')
    $rows = (Read-Control $Session chats).chats
    $ids = @($rows.id)
    Assert-That ($ids.Count -eq 5 -and (($ids | Sort-Object) -join ',') -ceq (($expected | Sort-Object) -join ',')) 'Workspace badge fixture list changed'
    $window = Get-Window $Session
    $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, '1016')
    $list = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
    Assert-That ($null -ne $list) 'Chat list not exposed to UI Automation'
    $handle = [IntPtr]$list.Current.NativeWindowHandle
    $client = [VerifyWindow+Rect]::new()
    $origin = [VerifyWindow+Point]::new()
    Assert-That ([VerifyWindow]::GetClientRect($handle, [ref]$client)) 'Cannot read list client bounds'
    Assert-That ([VerifyWindow]::ClientToScreen($handle, [ref]$origin)) 'Cannot read list screen origin'
    $rowHeight = [UIntPtr]::Zero
    $topIndex = [UIntPtr]::Zero
    Assert-That ([VerifyWindow]::ReadListMetric($handle, 0x01A1, [UIntPtr]::Zero, [IntPtr]::Zero, 2, 2000, [ref]$rowHeight) -ne [IntPtr]::Zero) 'Cannot read row height'
    Assert-That ([VerifyWindow]::ReadListMetric($handle, 0x018E, [UIntPtr]::Zero, [IntPtr]::Zero, 2, 2000, [ref]$topIndex) -ne [IntPtr]::Zero) 'Cannot read list scroll position'
    Assert-That ($topIndex.ToUInt64() -eq 0) 'Badge fixture is scrolled'
    $dpi = [VerifyWindow]::GetDpiForWindow($handle)
    $desktop = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $layout = [ordered]@{
        dpi = $dpi; row_height = $rowHeight.ToUInt64(); ids = $ids
        list_x = $origin.X - $desktop.Left; list_y = $origin.Y - $desktop.Top
        client_width = $client.Right; client_height = $client.Bottom
    }
    $layout | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Session.evidence 'workspace-icons-layout.json')
    foreach ($team in @('fixture-amber', 'fixture-cobalt', 'fixture-empty')) {
        $reply = Invoke-WebRequest -Uri "$($Session.bridge_url)/v1/wazig/workspace-icon/$team" -SkipHttpErrorCheck
        Assert-That ($reply.StatusCode -eq 401) 'Workspace icon route allowed unauthenticated access'
    }
    $null = Wait-Until {
        $requests = Read-BridgeRequests $Session
        foreach ($team in @('fixture-amber', 'fixture-cobalt', 'fixture-empty')) {
            $fetched = @($requests | Where-Object { $_.authorized -and $_.wire_path -eq "/v1/wazig/workspace-icon/$team" })
            $status = if ($team -eq 'fixture-empty') { 404 } else { 200 }
            if ($fetched.Count -ne 1 -or $fetched[0].status -ne $status) { return $false }
        }
        return $true
    } 'workspace icons fetched once per team'
    $null = Wait-Until {
        Save-Screen $Session workspace-icons-list
        & python "$PSScriptRoot/check-workspace-icons.py" $Session.evidence --capture | Out-Host
        $LASTEXITCODE -eq 0
    } 'visible workspace icons, green WhatsApp and blue Signal marks'
    Hub-Pass $Session workspace-icons-pixels
}
