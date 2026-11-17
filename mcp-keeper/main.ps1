. "$PSScriptRoot\lib\fuyu.ps1"
. "$PSScriptRoot\servers.ps1"

$script:View = 'servers'
$script:Running = @{}
$script:StartLimitMs = 30000

function T([string]$Zh, [string]$En) { New-FuyuText (ConvertFrom-FuyuEscape $Zh) $En }

function Get-Managed {
    $saved = Get-FuyuStorage 'managed'
    $managed = @{}
    if ($saved) { foreach ($p in $saved.PSObject.Properties) { $managed[$p.Name] = [int]$p.Value } }
    $managed
}

function Save-Managed($Managed) { Set-FuyuStorage 'managed' $Managed }

function Get-LogPath([string]$Name) {
    $dir = if ($env:FUYU_PLUGIN_DATA_DIR) { $env:FUYU_PLUGIN_DATA_DIR } else { $env:TEMP }
    Join-Path $dir ($Name + '.log')
}

function Get-Delay([int]$Failures) { [Math]::Min(60, 5 * [Math]::Pow(2, [Math]::Max(0, $Failures - 1))) }

function Start-Entry([string]$Name, $Config, [int]$Port, [bool]$Switch) {
    $launch = Get-Launch $Config $Port
    $entry = @{ launch = $launch; process = $null; failures = 0; nextAt = [DateTime]::MaxValue; error = $null; switch = $Switch; config = $Config; startedAt = [DateTime]::Now }
    $script:Running[$Name] = $entry
    if (-not (Clear-Port $launch)) { $entry.error = 'busy'; $entry.nextAt = [DateTime]::Now.AddSeconds(30); return }
    $entry.process = Start-Server $launch (Get-LogPath $Name)
    $entry.startedAt = [DateTime]::Now
    Write-FuyuLog "started $Name on $($launch.port) (pid $($entry.process.Id))"
}

function Stop-Entry([string]$Name) {
    $entry = $script:Running[$Name]
    if (-not $entry) { return }
    if ($entry.process -and -not $entry.process.HasExited) { Stop-Tree $entry.process.Id }
    $script:Running.Remove($Name)
}

function Complete-Switch([string]$Name, $Entry) {
    try {
        Set-FuyuSecret "orig-$Name" (Write-Json $Entry.config)
        $managed = Get-Managed
        $managed[$Name] = $Entry.launch.port
        Save-Managed $managed
        Set-UserMcp $Name (Write-Json @{ type = 'http'; url = (Get-ServerUrl $Entry.launch.port) })
        $Entry.switch = $false
        Write-FuyuLog "$Name now shared at $(Get-ServerUrl $Entry.launch.port)"
    } catch {
        Write-FuyuLog "switch $Name failed: $_"
        try { Set-UserMcp $Name (Write-Json $Entry.config) } catch {}
        $managed = Get-Managed
        $managed.Remove($Name)
        Save-Managed $managed
        Remove-FuyuSecret "orig-$Name"
        Stop-Entry $Name
        $script:Errors[$Name] = 'switch'
    }
}

function Update-Entries {
    foreach ($name in @($script:Running.Keys)) {
        $entry = $script:Running[$name]
        $alive = $entry.process -and -not $entry.process.HasExited
        if ($alive -and (Test-Listening $entry.launch.port)) {
            $entry.failures = 0; $entry.error = $null
            if ($entry.switch) { Complete-Switch $name $entry }
            continue
        }
        if ($alive -and $entry.switch -and ([DateTime]::Now - $entry.startedAt).TotalMilliseconds -gt $script:StartLimitMs) {
            Write-FuyuLog "$name did not listen on $($entry.launch.port) in time"
            Stop-Entry $name
            $script:Errors[$name] = 'start'
            continue
        }
        if ($alive) { continue }
        if ($entry.switch -and $entry.process) { Stop-Entry $name; $script:Errors[$name] = 'start'; continue }
        if ($entry.nextAt -eq [DateTime]::MaxValue) {
            $entry.failures++
            $entry.nextAt = [DateTime]::Now.AddSeconds((Get-Delay $entry.failures))
            Write-FuyuLog "$name exited; restart #$($entry.failures) at $($entry.nextAt.ToString('HH:mm:ss'))"
        } elseif ([DateTime]::Now -ge $entry.nextAt) {
            $failures = $entry.failures
            Start-Entry $name $entry.config $entry.launch.port $entry.switch
            $script:Running[$name].failures = $failures
        }
    }
}

function Start-AllManaged {
    $managed = Get-Managed
    $servers = Get-McpServers
    foreach ($name in @($managed.Keys)) {
        $json = Get-FuyuSecret "orig-$name"
        if (-not $json) { Write-FuyuLog "no saved config for $name"; continue }
        $current = $servers[$name]
        $switched = $current -and $current['url'] -eq (Get-ServerUrl $managed[$name])
        Start-Entry $name (Read-Json $json) $managed[$name] (-not $switched)
    }
}

function Get-Subtitle([string]$Name, $Launch, [bool]$IsManaged) {
    $entry = $script:Running[$Name]
    $port = $Launch.port
    if ($script:Errors.ContainsKey($Name)) {
        if ($script:Errors[$Name] -eq 'switch') { return T '\u6539\u914d\u7f6e\u5931\u8d25\uff0c\u5df2\u6062\u590d\u539f\u6837\uff1b\u8be6\u60c5\u770b\u63d2\u4ef6\u65e5\u5fd7' 'Could not change the config; put back as it was. See the plugin log' }
        return T "\u6ca1\u80fd\u5728\u7aef\u53e3 $port \u4e0a\u542f\u52a8\uff0c\u5df2\u6062\u590d\u539f\u6837\uff1b\u8be6\u60c5\u770b\u63d2\u4ef6\u65e5\u5fd7" "Did not start on port $port; put back as it was. See the plugin log"
    }
    if (-not $entry) {
        if ($IsManaged) { return T '\u5df2\u505c\u6b62' 'Stopped' }
        return T "\u52fe\u9009\u540e\u6240\u6709\u4f1a\u8bdd\u5171\u7528\u4e00\u4e2a\uff0c\u7aef\u53e3 $port" "Tick to share one among all sessions, port $port"
    }
    if ($entry.error -eq 'busy') { return T "\u7aef\u53e3 $port \u88ab\u522b\u7684\u7a0b\u5e8f\u5360\u7740\uff0c\u7a0d\u540e\u91cd\u8bd5" "Port $port is taken by another program; retrying" }
    if ($entry.switch) { return T '\u6b63\u5728\u542f\u52a8' 'Starting' }
    if ($entry.process -and -not $entry.process.HasExited -and $entry.failures -eq 0) { return T "\u5171\u4eab\u4e2d \u00b7 127.0.0.1:$port" "Shared \u00b7 127.0.0.1:$port" }
    T "\u5df2\u9000\u51fa\uff0c\u7b2c $($entry.failures) \u6b21\u91cd\u542f\u7b49\u5f85\u4e2d" "Exited; restart #$($entry.failures) pending"
}

function Get-MemoryLimitMb {
    try {
        $file = Join-Path $env:FUYU_PLUGIN_DATA_DIR '..\..\plugins.json'
        $limit = (Read-Json ([IO.File]::ReadAllText($file)))['plugins']['io.github.shenglin1001.mcp-keeper']['memoryLimitMb']
        if ($limit) { return [int]$limit }
    } catch {}
    return 512
}

function Show-Servers {
    try { $servers = Get-McpServers } catch { Update-FuyuView $script:View @{ error = (T '\u8bfb\u4e0d\u4e86 ~/.claude.json' 'Cannot read ~/.claude.json') }; return }
    $managed = Get-Managed
    $shareable = @(); $single = @()
    foreach ($name in @($servers.Keys | Sort-Object)) {
        $config = $servers[$name]
        $isManaged = $managed.ContainsKey($name)
        if ($isManaged) {
            $launch = if ($script:Running[$name]) { $script:Running[$name].launch } else { @{ port = $managed[$name] } }
            $shareable += @{ id = $name; title = $name; subtitle = (Get-Subtitle $name $launch $true); checked = $true; actions = @(@{ id = 'restart'; title = (T '\u91cd\u542f' 'Restart') }) }
            continue
        }
        if ((Get-Kind $config) -ne 'stdio') { continue }
        $launch = Get-Launch $config
        if ($launch) {
            $shareable += @{ id = $name; title = $name; subtitle = (Get-Subtitle $name $launch $false); checked = [bool]($script:Running[$name]) }
        } else {
            $single += @{ id = $name; title = $name; subtitle = (T '\u53ea\u4f1a stdio\uff0c\u6ca1\u6cd5\u5171\u7528\u4e00\u4e2a' 'Speaks stdio only; cannot be shared') }
        }
    }
    $groups = @()
    $limit = Get-MemoryLimitMb
    if ($shareable.Count -and $limit -lt 2048) {
        $tip = @{ id = 'memory-limit'; icon = 'info'; title = (T '\u628a\u5185\u5b58\u4e0a\u9650\u8c03\u5230 2 GB' 'Raise the memory limit to 2 GB'); subtitle = (T "\u73b0\u5728\u662f $limit MB\u3002\u5171\u4eab\u7684 server \u7b97\u5728\u63d2\u4ef6\u7684\u5185\u5b58\u91cc\uff0c\u4e09\u4e2a\u5408\u8ba1\u7ea6 800 MB\uff0c\u8d85\u4e86\u5c9b\u4f1a\u7ed3\u675f\u63d2\u4ef6\u3002\u5728 \u8bbe\u7f6e \u2192 \u63d2\u4ef6\u6269\u5c55 \u2192 MCP \u5e38\u9a7b \u2192 \u5185\u5b58\u4e0a\u9650 \u91cc\u6539" "It is $limit MB now. Shared servers count toward the plugin's memory, about 800 MB for all three, and the island stops the plugin past the limit. Change it under Settings > Plugins > MCP keeper > Memory limit") }
        $groups += @{ title = (T '\u6ce8\u610f' 'Note'); items = @($tip) }
    }
    if ($shareable.Count) { $groups += @{ title = (T '\u53ef\u4ee5\u5171\u4eab' 'Can be shared'); items = $shareable } }
    if ($single.Count) { $groups += @{ title = (T '\u4e0d\u652f\u6301\u5171\u4eab' 'Cannot be shared'); items = $single } }
    Update-FuyuView $script:View @{ groups = $groups; empty = (T '~/.claude.json \u91cc\u6ca1\u6709\u672c\u5730 MCP server' 'No local MCP servers in ~/.claude.json') }
}

function Enable-Server([string]$Name) {
    $script:Errors.Remove($Name)
    $config = (Get-McpServers)[$Name]
    if (-not $config -or -not (Get-Launch $config)) { return }
    Start-Entry $Name $config 0 $true
}

function Disable-Server([string]$Name) {
    $script:Errors.Remove($Name)
    Stop-Entry $Name
    $managed = Get-Managed
    if (-not $managed.ContainsKey($Name)) { return }
    $json = Get-FuyuSecret "orig-$Name"
    if ($json) { Set-UserMcp $Name $json }
    $managed.Remove($Name)
    Save-Managed $managed
    Remove-FuyuSecret "orig-$Name"
    Write-FuyuLog "$Name back to stdio"
}

$script:Errors = @{}
$script:Visible = $false

Invoke-FuyuLoop -OnIdle { Update-Entries; if ($script:Visible) { Show-Servers } } -Handlers @{
    initialize = { param($params) Start-AllManaged }
    'view.visible' = { param($params) $script:Visible = [bool]$params.visible; if ($script:Visible) { Show-Servers } }
    'view.action' = {
        param($params)
        $name = [string]$params.itemId
        if ($params.actionId -eq 'check') { if ($params.checked) { Enable-Server $name } else { Disable-Server $name } }
        elseif ($params.actionId -eq 'restart') { Stop-Entry $name; $port = (Get-Managed)[$name]; $json = Get-FuyuSecret "orig-$name"; if ($json) { Start-Entry $name (Read-Json $json) $port $false } }
        Show-Servers
    }
    shutdown = { param($params) foreach ($name in @($script:Running.Keys)) { Stop-Entry $name } }
}
