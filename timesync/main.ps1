# Time sync (API version 2): measures how far this clock is from the time server Windows syncs
# with, resyncs it through a scheduled task when it is off, and keeps the time zone where the user
# fixed it. Windows itself resyncs only every few hours and backs off after a failed DNS lookup,
# so a computer whose motherboard clock loses time can be hours off for a long while after boot.
#
# w32tm /resync needs administrator rights and the plugin has none: the task (resync-task.xml)
# runs as SYSTEM and lets signed-in users start it. Installing it asks for administrator rights once.
#
# This file must stay ASCII: Windows PowerShell 5.1 reads a script without a BOM in the ANSI
# code page. Chinese text is written as \u escapes and turned into text by Get-Text.
param(
    # For tests: an NTP server as host:port instead of the one Windows syncs with.
    [string]$Server = ''
)
. "$PSScriptRoot\lib\fuyu.ps1"

$TaskName = 'ResyncTimeOnNetwork'
$View = 'main'
# Off by more than this: resync. A clock Windows keeps in sync is well within a second.
$MaxOffsetSeconds = 2
# Off by at least this: tell the user, rather than fixing it silently.
$NoticeSeconds = 60
# After starting the task, how long w32tm gets before the clock is measured again.
$ResyncWaitMs = 8000
# Right after waking up the network may still be down: measure again a few times.
$RetryMs = 15000
$RetryCount = 3

$script:Settings = [pscustomobject]@{ timeZone = ''; language = 'zh-CN' }
$script:Visible = $false
# The last measurement: @{ at; server; offset = seconds the clock is behind the server, or $null }.
$script:Check = $null
$script:Retries = 0
# The task exists but refused to start: it was installed without the plugin's permission.
$script:Denied = $false

# Text in both languages. An argument that is itself such a text gives each language its own.
function Get-Text([string]$ZhCN, [string]$En, [object[]]$Arg = @()) {
    $lzh = @($Arg | ForEach-Object { if ($_ -is [hashtable]) { $_['zh-CN'] } else { $_ } })
    $len = @($Arg | ForEach-Object { if ($_ -is [hashtable]) { $_.en } else { $_ } })
    return New-FuyuText ((ConvertFrom-FuyuEscape $ZhCN) -f $lzh) ($En -f $len)
}

# "3 h 28 min", "1.25 s": the size of an offset.
function Format-Span([double]$Seconds) {
    $abs = [Math]::Abs($Seconds)
    if ($abs -lt 60) { return Get-Text '{0} \u79d2' '{0} s' @($abs.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)) }
    $span = [TimeSpan]::FromSeconds([Math]::Round($abs))
    if ($span.TotalHours -ge 1) { return Get-Text '{0} \u5c0f\u65f6 {1} \u5206' '{0} h {1} min' @([Math]::Floor($span.TotalHours), $span.Minutes) }
    return Get-Text '{0} \u5206 {1} \u79d2' '{0} min {1} s' @($span.Minutes, $span.Seconds)
}

function Get-Direction([double]$Offset) {
    if ($Offset -gt 0) { return Get-Text '\u6162' 'slow' }
    return Get-Text '\u5feb' 'fast'
}

# The first server Windows syncs with ("time.windows.com,0x9 ..." in the registry), as host and port.
function Get-TimeServer {
    $address = $Server
    if (-not $address) {
        $parameters = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction SilentlyContinue
        $address = (([string]$parameters.NtpServer).Trim() -split '\s+')[0] -replace ',.*$', ''
    }
    if (-not $address) { $address = 'time.windows.com' }
    $lpart = $address -split ':'
    if ($lpart.Count -eq 2) { return @{ host = $lpart[0]; port = [int]$lpart[1] } }
    return @{ host = $address; port = 123 }
}

# An NTP timestamp (seconds since 1900, big-endian, then a 32-bit fraction) as UTC.
function ConvertFrom-NtpTime([byte[]]$Bytes, [int]$At) {
    [double]$seconds = 0
    for ($index = 0; $index -lt 8; $index++) { $seconds = $seconds * 256 + $Bytes[$At + $index] }
    return (New-Object DateTime 1900, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)).AddSeconds($seconds / 4294967296.0)
}

# Seconds this clock is behind the server (negative: ahead), from one SNTP request (RFC 4330),
# or $null when the server does not answer. Needs no administrator rights.
function Measure-Offset($TimeServer) {
    $udp = New-Object Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = 3000
        $udp.Connect($TimeServer.host, $TimeServer.port)
        $request = New-Object byte[] 48
        $request[0] = 0x23  # version 4, client
        $sent = [DateTime]::UtcNow
        [void]$udp.Send($request, 48)
        $remote = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0
        $reply = $udp.Receive([ref]$remote)
        $received = [DateTime]::UtcNow
        # A server answer (mode 4) that is not a kiss-of-death (stratum 0).
        if ($reply.Length -lt 48 -or ($reply[0] -band 7) -ne 4 -or $reply[1] -eq 0) { return $null }
        $serverReceived = ConvertFrom-NtpTime $reply 32
        $serverSent = ConvertFrom-NtpTime $reply 40
        return ((($serverReceived - $sent).TotalSeconds) + (($serverSent - $received).TotalSeconds)) / 2
    } catch {
        Write-FuyuLog "no answer from $($TimeServer.host): $($_.Exception.Message)"
        return $null
    } finally {
        $udp.Close()
    }
}

function Update-Check {
    $timeServer = Get-TimeServer
    $script:Check = @{ at = [DateTime]::Now; server = $timeServer.host; offset = (Measure-Offset $timeServer) }
}

function Test-ClockOff {
    return $null -ne $script:Check.offset -and [Math]::Abs($script:Check.offset) -gt $MaxOffsetSeconds
}

function Get-Task {
    return Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
}

# Starts the task and measures again once w32tm had time to set the clock. $false when the
# task could not be started.
function Invoke-Resync {
    try {
        Start-ScheduledTask -TaskName $TaskName -TaskPath '\'
    } catch {
        Write-FuyuLog "cannot start the task: $($_.Exception.Message)"
        $script:Denied = $null -ne (Get-Task)
        return $false
    }
    $script:Denied = $false
    Start-Sleep -Milliseconds $ResyncWaitMs
    Update-Check
    return $true
}

# Runs a PowerShell script as administrator after Windows asked the user; returns when it
# ended, or at once when the user said no.
function Invoke-Elevated([string]$Script) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ErrorActionPreference = 'Stop'; $Script"))
    try {
        Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    } catch {
        Write-FuyuLog "not run as administrator: $($_.Exception.Message)"
    }
}

function Install-Task {
    $path_xml = (Join-Path $PSScriptRoot 'resync-task.xml') -replace "'", "''"
    Invoke-Elevated "Register-ScheduledTask -TaskName '$TaskName' -TaskPath '\' -Xml (Get-Content -Raw -Encoding UTF8 '$path_xml') -Force | Out-Null"
    $script:Denied = $false
}

function Remove-Task {
    Invoke-Elevated "Unregister-ScheduledTask -TaskName '$TaskName' -TaskPath '\' -Confirm:`$false"
}

# Whether the plugin said this within the last $Hours; if not, remembers that it says it now.
function Test-Said([string]$Key, [double]$Hours) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $last = Get-FuyuStorage $Key
    if ($null -ne $last -and [Math]::Abs($now - [double]$last) -lt $Hours * 3600) { return $true }
    Set-FuyuStorage $Key $now
    return $false
}

# island.notify takes plain strings: the language comes from the plugin's setting.
function Send-Notice($Title, $Body, [object[]]$Actions = $null) {
    $language = if ($script:Settings.language -eq 'en') { 'en' } else { 'zh-CN' }
    $lactionText = @($Actions | Where-Object { $_ } | ForEach-Object { @{ id = $_.id; title = $_.title[$language] } })
    [void](Show-FuyuNotification $Title[$language] $Body[$language] $lactionText)
}

# Puts the time zone back when something changed it, if the user fixed one in the settings.
function Repair-TimeZone {
    $want = [string]$script:Settings.timeZone
    [TimeZoneInfo]::ClearCachedData()
    $zone = [TimeZoneInfo]::Local
    if (-not $want -or $zone.Id -eq $want) { return }
    try {
        Set-TimeZone -Id $want
    } catch {
        Write-FuyuLog "cannot switch to time zone '$want': $($_.Exception.Message)"
        return
    }
    [TimeZoneInfo]::ClearCachedData()
    Send-Notice (Get-Text '\u65f6\u533a\u88ab\u6539\u6210\u4e86 {0}\uff0c\u5df2\u6539\u56de' 'The time zone was changed to {0}; put back' @($zone.Id)) (Get-Text '\u8981\u6362\u65f6\u533a\uff0c\u5148\u5728\u63d2\u4ef6\u8bbe\u7f6e\u91cc\u6539\u300c\u56fa\u5b9a\u65f6\u533a\u300d\u3002' 'To change it, first change Fixed time zone in the plugin settings.')
}

# Measures the clock and resyncs it when it is off; says so when it was far off or could not be fixed.
function Invoke-Check {
    Repair-TimeZone
    Update-Check
    if (-not (Test-ClockOff)) { Show-Page; return }
    $before = $script:Check.offset
    $off = Get-Text '\u65f6\u949f{0}\u4e86 {1}' 'The clock was {1} {0}' @((Get-Direction $before), (Format-Span $before))
    if ($null -eq (Get-Task)) {
        if ([Math]::Abs($before) -ge $NoticeSeconds -and -not (Test-Said 'askedInstall' 168)) {
            Send-Notice $off (Get-Text '\u5b89\u88c5\u6821\u65f6\u4efb\u52a1\u540e\u63d2\u4ef6\u80fd\u81ea\u52a8\u6821\u6b63\uff0c\u5b89\u88c5\u65f6\u8981\u7ba1\u7406\u5458\u786e\u8ba4\u4e00\u6b21\u3002' 'Install the resync task and the plugin fixes it; installing asks for administrator rights once.') @(@{ id = 'install'; title = (Get-Text '\u5b89\u88c5' 'Install') })
        }
        Show-Page
        return
    }
    $started = Invoke-Resync
    if ($started -and -not (Test-ClockOff)) {
        if ([Math]::Abs($before) -ge $NoticeSeconds) { Send-Notice $off (Get-Text '\u5df2\u7ecf\u6821\u6b63\u3002' 'Fixed now.') }
    } elseif (-not (Test-Said 'failedAt' 1)) {
        $why = if ($started) { Get-Text '\u6821\u65f6\u4efb\u52a1\u8dd1\u4e86\uff0c\u65f6\u949f\u8fd8\u662f\u4e0d\u51c6\u3002\u770b\u770b\u7f51\u7edc\uff0c\u6216\u5728\u9875\u9762\u4e0a\u518d\u8bd5\u4e00\u6b21\u3002' 'The resync task ran but the clock is still off. Check the network, or try again on the page.' } else { Get-Text '\u63d2\u4ef6\u6ca1\u6709\u6743\u9650\u542f\u52a8\u6821\u65f6\u4efb\u52a1\uff0c\u8bf7\u5728\u9875\u9762\u4e0a\u91cd\u65b0\u5b89\u88c5\u3002' 'The plugin may not start the resync task; reinstall it on the page.' }
        Send-Notice $off $why
    }
    Show-Page
}

function Get-ClockItem {
    $check = $script:Check
    $at = $check.at.ToString('HH:mm')
    $item = @{ id = 'clock'; title = (Get-Text '\u65f6\u949f' 'Clock'); icon = 'clock' }
    if ($null -eq $check.offset) {
        $item.subtitle = Get-Text '{0} \u6ca1\u6709\u56de\u5e94\uff08{1}\uff09\uff0c\u53ef\u80fd\u8fd8\u6ca1\u8054\u7f51' 'No answer from {0} (at {1}); offline?' @($check.server, $at)
        $item.note = '-'
    } elseif (-not (Test-ClockOff)) {
        $item.subtitle = Get-Text '\u548c {0} \u76f8\u5dee {1}\uff08{2} \u6d4b\uff09' 'Within {1} of {0} (at {2})' @($check.server, (Format-Span $check.offset), $at)
        $item.note = Get-Text '\u51c6' 'OK'
    } else {
        $item.subtitle = Get-Text '\u6bd4 {0} {1} {2}\uff08{3} \u6d4b\uff09' '{2} {1} against {0} (at {3})' @($check.server, (Get-Direction $check.offset), (Format-Span $check.offset), $at)
        $item.note = Get-Text '\u4e0d\u51c6' 'Off'
    }
    if ($null -ne (Get-Task) -and -not $script:Denied) { $item.actions = @(@{ id = 'resync'; title = (Get-Text '\u7acb\u5373\u6821\u65f6' 'Sync now') }) }
    return $item
}

function Get-TaskItem {
    $item = @{ id = 'task'; title = (Get-Text '\u6821\u65f6\u4efb\u52a1' 'Resync task'); icon = 'timer' }
    if ($null -eq (Get-Task)) {
        $item.subtitle = Get-Text '\u672a\u5b89\u88c5\u3002\u88c5\u4e0a\u540e\u5f00\u673a\u548c\u6bcf\u6b21\u8054\u7f51\u90fd\u7acb\u5373\u6821\u65f6\uff0c\u5c9b\u6ca1\u5f00\u4e5f\u4e00\u6837\uff1b\u5b89\u88c5\u8981\u7ba1\u7406\u5458\u786e\u8ba4\u4e00\u6b21' 'Not installed. Once installed, Windows resyncs at startup and on every network connection, island or not; installing asks for administrator rights once'
        $item.actions = @(@{ id = 'install'; title = (Get-Text '\u5b89\u88c5' 'Install') })
    } elseif ($script:Denied) {
        $item.subtitle = Get-Text '\u5df2\u5b89\u88c5\uff0c\u4f46\u63d2\u4ef6\u6ca1\u6709\u6743\u9650\u542f\u52a8\u5b83\uff08\u4e0d\u662f\u63d2\u4ef6\u88c5\u7684\uff09\uff0c\u91cd\u65b0\u5b89\u88c5\u5373\u53ef' 'Installed, but the plugin may not start it (it did not install it); reinstall it'
        $item.actions = @(@{ id = 'install'; title = (Get-Text '\u91cd\u65b0\u5b89\u88c5' 'Reinstall') }, @{ id = 'uninstall'; title = (Get-Text '\u5378\u8f7d' 'Remove') })
    } else {
        $item.subtitle = Get-Text '\u5df2\u5b89\u88c5\uff1a\u5f00\u673a\u548c\u6bcf\u6b21\u8054\u7f51\u540e\u7acb\u5373\u6821\u65f6\uff0c\u5c9b\u6ca1\u5f00\u4e5f\u4e00\u6837' 'Installed: resyncs at startup and on every network connection, island or not'
        $item.actions = @(@{ id = 'uninstall'; title = (Get-Text '\u5378\u8f7d' 'Remove') })
    }
    return $item
}

function Get-ZoneItem {
    [TimeZoneInfo]::ClearCachedData()
    $zone = [TimeZoneInfo]::Local
    $want = [string]$script:Settings.timeZone
    $item = @{ id = 'zone'; title = $zone.DisplayName; icon = 'globe' }
    if (-not $want) {
        $item.subtitle = Get-Text '\u65f6\u533a\u6ca1\u6709\u56fa\u5b9a' 'Time zone not fixed'
        $item.actions = @(@{ id = 'lock'; title = (Get-Text '\u56fa\u5b9a' 'Fix') })
    } elseif ($want -eq $zone.Id) {
        $item.subtitle = Get-Text '\u5df2\u56fa\u5b9a\uff1a\u88ab\u522b\u7684\u7a0b\u5e8f\u6539\u6389\u65f6\u81ea\u52a8\u6539\u56de' 'Fixed: put back when something changes it'
        $item.actions = @(@{ id = 'unlock'; title = (Get-Text '\u53d6\u6d88\u56fa\u5b9a' 'Unfix') })
    } else {
        $item.subtitle = Get-Text '\u8bbe\u7f6e\u91cc\u56fa\u5b9a\u7684\u300c{0}\u300d\u4e0d\u662f\u6709\u6548\u7684\u65f6\u533a ID' 'The fixed time zone in the settings, {0}, is not a valid id' @($want)
        $item.actions = @(@{ id = 'unlock'; title = (Get-Text '\u53d6\u6d88\u56fa\u5b9a' 'Unfix') })
    }
    return $item
}

function Show-Page {
    if (-not $script:Visible) { return }
    if ($null -eq $script:Check) { Update-Check }
    Update-FuyuView $View @{ items = @((Get-ClockItem), (Get-TaskItem), (Get-ZoneItem)) }
}

function Set-FixedZone([string]$Id) {
    Set-FuyuSetting @{ timeZone = $Id }
    $script:Settings.timeZone = $Id
}

function Invoke-Action([string]$Id) {
    switch ($Id) {
        'resync' { if (-not (Invoke-Resync)) { Send-Notice (Get-Text '\u6ca1\u80fd\u6821\u65f6' 'Could not resync') (Get-Text '\u6821\u65f6\u4efb\u52a1\u6ca1\u88c5\uff0c\u6216\u63d2\u4ef6\u6ca1\u6709\u6743\u9650\u542f\u52a8\u5b83\uff1a\u5148\u5b89\u88c5\u6821\u65f6\u4efb\u52a1\u3002' 'The resync task is missing or the plugin may not start it: install it first.') } }
        'install' { Install-Task; Invoke-Check }
        'uninstall' { Remove-Task }
        'lock' { [TimeZoneInfo]::ClearCachedData(); Set-FixedZone ([TimeZoneInfo]::Local.Id) }
        'unlock' { Set-FixedZone '' }
    }
    Show-Page
}

Invoke-FuyuLoop @{
    initialize = {
        param($params)
        if ($null -ne $params.settings) { $script:Settings = $params.settings }
        Invoke-Check
    }
    'settings.changed' = {
        param($params)
        $script:Settings = $params.settings
        Repair-TimeZone
        Show-Page
    }
    'view.visible' = {
        param($params)
        $script:Visible = [bool]$params.visible
        # Opening the page measures at once rather than showing an old reading.
        if ($script:Visible) { Update-Check; Show-Page }
    }
    'view.action' = { param($params) Invoke-Action $params.actionId }
    # The same buttons on the plugin's settings page, where people look for them first.
    command = { param($params) Invoke-Action $params.id }
    'notification.action' = {
        param($params)
        if ($params.id -eq 'install') { Install-Task; Invoke-Check }
    }
} -TimeoutMs $RetryMs -OnIdle {
    if ($null -ne $script:Check -and $null -eq $script:Check.offset -and $script:Retries -lt $RetryCount) {
        $script:Retries++
        Invoke-Check
    }
}
