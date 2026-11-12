# Battery (API version 2): this computer's battery and the connected Bluetooth devices' levels
# as upright batteries side by side on the collapsed bar (no numbers there: hovering shows them),
# plus a page listing every device. Read every 20 s from
# what Windows already knows (power.ps1); nothing is asked of the devices themselves. Apple
# earphones, which Windows has no level for, broadcast theirs: the plugin listens for that
# for a few seconds each minute while such earphones are connected (adverts.cs).
#
# This file must stay ASCII: Windows PowerShell 5.1 reads a script without a BOM in the ANSI
# code page. Chinese text is written as \u escapes and turned into text by Get-Text.
. "$PSScriptRoot\lib\fuyu.ps1"
. "$PSScriptRoot\power.ps1"

$PollMs = 20000
# The bar draws at most this many batteries: this computer's, then the connected devices'.
$BarBatteries = 4
# What the bar and page show now, so a reading that changes nothing sends nothing.
$script:Shown = ''
# How long the plugin listens for earphones' broadcasts, and how often.
$ListenMs = 5000
$ListenEveryMs = 60000
$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:ListenedAt = -$ListenEveryMs
# $null until the listener was needed; then whether it could be built.
$script:Listener = $null
# Address -> { left, right, case } last heard from each connected pair of earphones.
$script:Heard = @{}

function Get-Text([string]$ZhCN, [string]$En) {
    return New-FuyuText (ConvertFrom-FuyuEscape $ZhCN) $En
}

# Yellow from 20 %, red from 10 %; above that the island gives each battery its place's color.
# A computer that is plugged in is not running low, whatever its level.
function Get-Tone([int]$Percent, [bool]$Plugged) {
    if ($Plugged -or $Percent -gt 20) { return 'neutral' }
    if ($Percent -le 10) { return 'danger' }
    return 'warning'
}

# A device name short enough that four of them fit the tooltip (200 characters).
function Get-Label([string]$Name) {
    $info = New-Object Globalization.StringInfo -ArgumentList ([string]$Name).Trim()
    if ($info.LengthInTextElements -eq 0) { return 'BT' }
    return $info.SubstringByTextElements(0, [Math]::Min(30, $info.LengthInTextElements)).Trim()
}

# Gives connected Apple earphones the level they last broadcast, the emptier pod's, and
# listens again when it is time. A pair that falls silent keeps its level while connected.
function Add-BroadcastLevels($Devices) {
    $lneeded = @($Devices | Where-Object { $_.Connected -and $_.Percent -lt 0 -and $_.AppleModel -ge 0 })
    if ($lneeded.Count -eq 0) { $script:Heard = @{}; return }
    if ($null -eq $script:Listener) {
        try {
            Import-AppleAdverts
            $script:Listener = $true
        } catch {
            $script:Listener = $false
            Write-FuyuLog "no earphone levels: $($_.Exception.Message)"
        }
    }
    if (-not $script:Listener) { return }
    $dict_heard = @{}
    foreach ($device in $lneeded) {
        $parts = [FocusdAppleAdverts]::Read($device.AppleModel)
        if ($null -eq $parts) { $parts = $script:Heard[$device.Address] }
        if ($null -eq $parts) { continue }
        $dict_heard[$device.Address] = $parts
        $lpod = @($parts[0], $parts[1] | Where-Object { $_ -ge 0 } | Sort-Object)
        if ($lpod.Count -gt 0) { $device.Percent = $lpod[0] }
    }
    $script:Heard = $dict_heard
    if ($script:Clock.ElapsedMilliseconds - $script:ListenedAt -ge $ListenEveryMs) {
        [FocusdAppleAdverts]::Listen($ListenMs)
        $script:ListenedAt = $script:Clock.ElapsedMilliseconds
    }
}

function Read-Levels {
    $ldevice = @([FocusdPower]::Devices())
    Add-BroadcastLevels $ldevice
    return @{
        battery = [FocusdPower]::Battery()
        devices = @($ldevice | Sort-Object @{ Expression = { $_.Percent } }, @{ Expression = { $_.Name } })
    }
}

# This computer first, then the connected devices by name rather than by level: a battery
# keeps its place on the bar, and with it its color, while the levels change.
function Show-Bar($Levels) {
    $lshown = @()
    if ($null -ne $Levels.battery) { $lshown += @{ name = 'PC'; percent = $Levels.battery[0]; plugged = ($Levels.battery[1] -eq 1) } }
    $ldevice = @($Levels.devices | Where-Object { $_.Connected -and $_.Percent -ge 0 } | Sort-Object Name, Address | Select-Object -First ($BarBatteries - $lshown.Count))
    $lshown += @($ldevice | ForEach-Object { @{ name = (Get-Label $_.Name); percent = $_.Percent; plugged = $false } })
    if ($lshown.Count -eq 0) {
        Clear-FuyuStatus 'battery'
        return
    }
    $batteries = @($lshown | ForEach-Object { @{ level = $_.percent / 100; tone = (Get-Tone $_.percent $_.plugged) } })
    # The text is what a screen reader says, and what an island that cannot draw batteries shows.
    $text = @($lshown | ForEach-Object { "$($_.percent)%" }) -join ' '
    $tooltip = @($lshown | ForEach-Object { "$($_.name) $($_.percent)%" }) -join ' / '
    Update-FuyuStatus 'battery' $text -Tooltip $tooltip -Batteries $batteries
}

function Get-BatteryItem($Battery) {
    $subtitle = Get-Text '\u7528\u7535\u6c60' 'On battery'
    if ($Battery[1] -eq 1) {
        $subtitle = Get-Text '\u5df2\u63a5\u901a\u7535\u6e90' 'Plugged in'
    } elseif ($Battery[2] -gt 0) {
        $hours = [Math]::Floor($Battery[2] / 3600)
        $minutes = [Math]::Floor(($Battery[2] % 3600) / 60)
        $subtitle = New-FuyuText ((ConvertFrom-FuyuEscape '\u7528\u7535\u6c60\uff0c\u7ea6\u5269 {0} \u5c0f\u65f6 {1} \u5206') -f $hours, $minutes) ('On battery, about {0} h {1} min left' -f $hours, $minutes)
    }
    return @{ id = 'pc'; title = (Get-Text '\u8fd9\u53f0\u7535\u8111' 'This computer'); subtitle = $subtitle; note = "$($Battery[0])%"; icon = 'zap' }
}

# "Connected, left 30%, right 40%" for earphones whose levels came from their broadcast.
function Get-PartsText($Parts) {
    $lchinese = @('\u5df2\u8fde\u63a5')
    $lenglish = @('Connected')
    $lname = @(@('\u5de6', 'left'), @('\u53f3', 'right'), @('\u5145\u7535\u76d2', 'case'))
    for ($index = 0; $index -lt 3; $index++) {
        if ($Parts[$index] -lt 0) { continue }
        $lchinese += "$($lname[$index][0]) $($Parts[$index])%"
        $lenglish += "$($lname[$index][1]) $($Parts[$index])%"
    }
    return Get-Text ($lchinese -join '\uff0c') ($lenglish -join ', ')
}

function Get-DeviceItem($Device) {
    $name = if ($Device.Name) { $Device.Name } else { $Device.Address }
    $item = @{ id = 'bt:' + $Device.Address; title = $name; icon = 'link'; note = '-' }
    if ($Device.Percent -ge 0) { $item.note = "$($Device.Percent)%" }
    if (-not $Device.Connected) { return $item }
    $parts = $script:Heard[$Device.Address]
    $item.subtitle = if ($null -ne $parts) { Get-PartsText $parts } elseif ($Device.Percent -ge 0) { Get-Text '\u5df2\u8fde\u63a5' 'Connected' } else { Get-Text '\u5df2\u8fde\u63a5\uff0cWindows \u6ca1\u6709\u5b83\u7684\u7535\u91cf' 'Connected; Windows has no level for it' }
    return $item
}

# Connected devices first; below them the ones Windows remembers a level for.
function Show-Page($Levels) {
    $lnow = @()
    if ($null -ne $Levels.battery) { $lnow += Get-BatteryItem $Levels.battery }
    $lnow += @($Levels.devices | Where-Object { $_.Connected } | ForEach-Object { Get-DeviceItem $_ })
    $laway = @($Levels.devices | Where-Object { -not $_.Connected -and $_.Percent -ge 0 } | ForEach-Object { Get-DeviceItem $_ })
    $groups = @()
    if ($lnow.Count -gt 0) { $groups += @{ items = $lnow } }
    if ($laway.Count -gt 0) { $groups += @{ title = (Get-Text '\u672a\u8fde\u63a5\uff08\u4e0a\u6b21\u8bfb\u5230\u7684\u7535\u91cf\uff09' 'Not connected (last level read)'); items = $laway } }
    Update-FuyuView 'levels' @{
        groups = $groups
        empty  = Get-Text '\u8fd9\u53f0\u7535\u8111\u6ca1\u6709\u7535\u6c60\uff0c\u4e5f\u6ca1\u6709\u914d\u5bf9\u7684\u84dd\u7259\u8bbe\u5907\u3002' 'This computer has no battery and no paired Bluetooth device.'
    }
}

function Update-Levels {
    $levels = Read-Levels
    $signature = "$($levels.battery -join ',')|" + (@($levels.devices | ForEach-Object { "$($_.Address):$($_.Percent):$($_.Connected):$($_.Name):$($script:Heard[$_.Address] -join '/')" }) -join ';')
    if ($signature -eq $script:Shown) { return }
    Show-Bar $levels
    Show-Page $levels
    $script:Shown = $signature
}

Invoke-FuyuLoop @{
    initialize = {
        # The bar's items are cleared when the plugin stops, so it stays running.
        Set-FuyuKeepAlive 'Shows battery levels on the collapsed bar'
        Update-Levels
    }
    'view.visible' = {
        param($params)
        # Opening the page reads at once rather than waiting for the next poll.
        if ($params.visible) { $script:Shown = ''; Update-Levels }
    }
} -TimeoutMs $PollMs -OnIdle { Update-Levels }
