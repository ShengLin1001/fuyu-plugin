# Job queue (API version 2): the user's own Slurm jobs on the computers ticked in the island under
# Settings > AI Agent > Remote computers, and in WSL when it is running. The collapsed bar shows
# one total (a pie once the island draws one, else "R12 PD3 CG1"), the page lists every job by
# computer.
#
# Each computer is asked every 60 s, all at once: ssh runs the login shell and the plugin sends it
# a short script (queue.ps1). squeue fails now and then (slurmctld busy, the network), so a failed
# computer is asked again every 5 s, up to 99 times, before going back to the 60 s round; meanwhile
# its last jobs stay on the page, marked as old.
#
# This file must stay ASCII: Windows PowerShell 5.1 reads a script without a BOM in the ANSI
# code page. Chinese text is written as \u escapes.
. "$PSScriptRoot\lib\fuyu.ps1"
. "$PSScriptRoot\queue.ps1"

$TickMs = 1000
$PollMs = 60000
$RetryMs = 5000
$RetryMax = 99
# A shell that has not answered by then is stopped and counts as a failure.
$QueryTimeoutMs = 60000
# The bar warns when a computer has failed for this long; shorter outages only grey the page.
$AlertMs = 300000
$StatusId = 'queue'
$ViewId = 'jobs'
# Tests point this at a fake ssh.
$SshExe = if ($env:FUYU_SQUEUE_SSH) { $env:FUYU_SQUEUE_SSH } else { 'ssh' }
# The same options the island's own ssh uses; the user's tunnels must not be opened again.
$SshOptions = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=3', '-o', 'ClearAllForwardings=yes', '-o', 'LogLevel=ERROR', '-T')
$WslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'

$script:AppDir = $null
$script:HostsStamp = $null
$script:HostsError = $null
# Key ('wsl' or 'ssh:<name>') -> source, in the order shown.
$script:Sources = [ordered]@{}
$script:Dirty = $true
$script:Alert = $false
$script:CanPie = $false
# The island's language, which only the page knows: it says so when it opens.
$script:Locale = 'zh-CN'

function Get-Now { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function New-Source([string]$Key, [string]$Name, [bool]$Local, [string]$Exe, [string[]]$Arguments) {
    return @{
        key = $Key; name = $Name; local = $Local; exe = $Exe; args = $Arguments
        process = $null; stdout = $null; stderr = $null; startedAt = 0; nextAt = 0
        # $null until a query succeeded; then the jobs it found, kept through later failures.
        jobs = $null; updatedAt = 0; skipped = $true
        error = $null; failures = 0; failingSince = 0
    }
}

# Runs a short Windows command and returns its output, or $null when it failed or took too long.
function Invoke-Quick([string]$Exe, [string]$Arguments, [Text.Encoding]$Encoding) {
    $info = New-Object Diagnostics.ProcessStartInfo -ArgumentList $Exe, $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.StandardOutputEncoding = $Encoding
    try { $process = [Diagnostics.Process]::Start($info) } catch { return $null }
    $output = $process.StandardOutput.ReadToEndAsync()
    if (-not $process.WaitForExit(10000)) { try { $process.Kill() } catch { }; return $null }
    if ($process.ExitCode -ne 0) { return $null }
    return $output.Result
}

# The default WSL distribution when it is already running, else $null: asking a stopped one
# would start its virtual machine every minute.
function Get-RunningWsl {
    if (-not (Test-Path -LiteralPath $WslExe)) { return $null }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $guid = (Get-ItemProperty -LiteralPath $key -Name DefaultDistribution -ErrorAction SilentlyContinue).DefaultDistribution
    if (-not $guid) { return $null }
    $name = (Get-ItemProperty -LiteralPath "$key\$guid" -Name DistributionName -ErrorAction SilentlyContinue).DistributionName
    if (-not $name) { return $null }
    # wsl.exe writes UTF-16; it exits non-zero when nothing is running.
    $running = Invoke-Quick $WslExe '-l --running -q' ([Text.Encoding]::Unicode)
    if ($null -eq $running) { return $null }
    $lrunning = @($running -split "`r?`n" | ForEach-Object { $_.Trim([char]0, ' ') })
    if ($lrunning -contains $name) { return $name }
    return $null
}

# Brings the sources in line with the island's list of computers when that file changed.
function Sync-Sources {
    $path_hosts = Join-Path $script:AppDir 'agent-remote-hosts.json'
    $stamp = if (Test-Path -LiteralPath $path_hosts) { (Get-Item -LiteralPath $path_hosts).LastWriteTimeUtc.Ticks } else { 0 }
    if ($stamp -eq $script:HostsStamp) { return }
    $script:HostsStamp = $stamp
    try {
        $lhost = @(Get-RemoteHosts $script:AppDir)
        $script:HostsError = $null
    } catch {
        $lhost = @()
        $script:HostsError = "Cannot read the island's list of remote computers: $($_.Exception.Message)"
        Write-FuyuLog $script:HostsError
    }
    $dict_source = [ordered]@{}
    $dict_source['wsl'] = if ($script:Sources.Contains('wsl')) { $script:Sources['wsl'] } else { New-Source 'wsl' 'WSL' $true $WslExe @() }
    foreach ($remote in $lhost) {
        $key = 'ssh:' + $remote.name
        $largs = @($SshOptions + $remote.args)
        $old = $script:Sources[$key]
        if ($null -ne $old -and (($old.args -join ' ') -eq ($largs -join ' '))) {
            $dict_source[$key] = $old
        } else {
            $dict_source[$key] = New-Source $key $remote.name $false $SshExe $largs
        }
    }
    foreach ($key in @($script:Sources.Keys)) {
        $old = $script:Sources[$key]
        if (-not $dict_source.Contains($key) -and $null -ne $old.process) { try { $old.process.Kill() } catch { } }
    }
    $script:Sources = $dict_source
    $script:Dirty = $true
}

function Join-Arguments([string[]]$Arguments) {
    return (@($Arguments) | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
}

function Set-Failure($Source, [string]$Reason, [long]$Now) {
    $Source.error = $Reason
    $Source.skipped = $false
    if ($Source.failingSince -eq 0) { $Source.failingSince = $Now }
    $Source.failures++
    if ($Source.failures -le $RetryMax) {
        $Source.nextAt = $Now + $RetryMs
    } else {
        # Out of retries: back to the normal round, and a fresh set of retries after it.
        $Source.failures = 0
        $Source.nextAt = $Now + $PollMs
    }
    Write-FuyuLog "$($Source.name): $Reason"
    $script:Dirty = $true
}

function Start-Query($Source, [long]$Now) {
    $largs = $Source.args
    if ($Source.local) {
        $distro = Get-RunningWsl
        if ($null -eq $distro) {
            if (-not $Source.skipped) { $Source.skipped = $true; $Source.jobs = $null; $script:Dirty = $true }
            $Source.nextAt = $Now + $PollMs
            return
        }
        $Source.name = "WSL $distro"
        $largs = @('-d', $distro, '-e', 'sh', '-l', '-s')
    }
    $info = New-Object Diagnostics.ProcessStartInfo -ArgumentList $Source.exe, (Join-Arguments $largs)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $fuyuUtf8
    $info.StandardErrorEncoding = $fuyuUtf8
    try {
        $process = [Diagnostics.Process]::Start($info)
    } catch {
        Set-Failure $Source "Cannot start $($Source.exe): $($_.Exception.Message)" $Now
        return
    }
    $Source.process = $process
    $Source.stdout = $process.StandardOutput.ReadToEndAsync()
    $Source.stderr = $process.StandardError.ReadToEndAsync()
    $Source.startedAt = $Now
    try {
        # The bytes themselves: a writer could put a BOM before the script's first command.
        $bytes = $fuyuUtf8.GetBytes((Get-SqueueScript $Source.local))
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
    } catch {
        # The shell already ended; its exit code and stderr tell why.
    }
}

function Complete-Query($Source, [long]$Now) {
    $process = $Source.process
    $Source.process = $null
    $exitCode = $process.ExitCode
    $stdout = $Source.stdout.Result
    $stderr = $Source.stderr.Result
    $process.Dispose()
    if ($Source.local -and $exitCode -eq $NoSqueueExit) {
        if (-not $Source.skipped) { $Source.skipped = $true; $Source.jobs = $null; $script:Dirty = $true }
        $Source.nextAt = $Now + $PollMs
        return
    }
    # Only a clean exit counts: an empty answer from a failed squeue is not an empty queue.
    $ljob = if ($exitCode -eq 0) { ConvertFrom-SqueueOutput $stdout } else { $null }
    if ($null -eq $ljob) {
        Set-Failure $Source (Get-FailureReason $stderr $exitCode) $Now
        return
    }
    $Source.jobs = @($ljob)
    $Source.updatedAt = $Now
    $Source.skipped = $false
    $Source.error = $null
    $Source.failures = 0
    $Source.failingSince = 0
    $Source.nextAt = $Now + $PollMs
    $script:Dirty = $true
}

function Update-Sources {
    $now = Get-Now
    Sync-Sources
    foreach ($source in @($script:Sources.Values)) {
        if ($null -ne $source.process) {
            if ($source.process.HasExited) {
                Complete-Query $source $now
            } elseif ($now - $source.startedAt -gt $QueryTimeoutMs) {
                try { $source.process.Kill() } catch { }
                $source.process = $null
                Set-Failure $source 'No answer within 60 s' $now
            }
        } elseif ($now -ge $source.nextAt) {
            Start-Query $source $now
        }
    }
    $alert = @($script:Sources.Values | Where-Object { $_.failingSince -gt 0 -and $now - $_.failingSince -ge $AlertMs }).Count -gt 0
    if ($alert -ne $script:Alert) { $script:Alert = $alert; $script:Dirty = $true }
    if ($script:Dirty) {
        $script:Dirty = $false
        Show-Queue $now
    }
}

function Get-Text([string]$ZhCN, [string]$En) {
    if ($script:Locale -eq 'zh-CN') { return ConvertFrom-FuyuEscape $ZhCN }
    return $En
}

# The computers that answered at least once or are failing; a WSL without Slurm is left out.
function Get-ShownSources {
    return @($script:Sources.Values | Where-Object { -not $_.skipped })
}

function Show-Bar([long]$Now) {
    $lsource = @(Get-ShownSources)
    $counts = Get-StateCounts @($lsource | ForEach-Object { $_.jobs })
    $text = "R$($counts.R) PD$($counts.PD) CG$($counts.CG)"
    if ($counts.other -gt 0) { $text += " +$($counts.other)" }
    if ($script:Alert) { $text += ' !' }
    $tooltip = "R $($counts.R) / PD $($counts.PD) / CG $($counts.CG) / " + (Get-Text '\u5176\u4ed6' 'other') + " $($counts.other)"
    if ($lsource.Count -eq 0) {
        $tooltip = Get-Text '\u6ca1\u6709\u53ef\u4ee5\u67e5\u7684\u7535\u8111\uff1a\u5728 \u8bbe\u7f6e \u2192 AI Agent \u2192 \u8fdc\u7a0b\u7535\u8111 \u91cc\u52fe\u9009' 'No computer to ask: tick some under Settings > AI Agent > Remote computers'
    }
    foreach ($source in @($lsource | Where-Object { $_.failingSince -gt 0 })) {
        $minutes = [Math]::Floor(($Now - $source.failingSince) / 60000)
        $tooltip += '; ' + $source.name + ' ' + ((Get-Text '\u67e5\u8be2\u5931\u8d25 {0} \u5206\u949f' 'failing for {0} min') -f $minutes)
    }
    if ($tooltip.Length -gt 200) { $tooltip = $tooltip.Substring(0, 199) + [char]0x2026 }
    $params = @{ itemId = $StatusId; text = $text; tooltip = $tooltip }
    if ($script:Alert) { $params.tone = 'warning' }
    if ($script:CanPie) {
        # Without tones the island colours the slices by place: R, PD, CG, other.
        $params.pie = @(@{ value = $counts.R }, @{ value = $counts.PD }, @{ value = $counts.CG }, @{ value = $counts.other })
    }
    [void](Invoke-FuyuMethod 'status.update' $params)
}

# Everything the page draws; it does its own wording in the island's language.
function Get-PageModel([long]$Now) {
    $lhost = @(Get-ShownSources | ForEach-Object {
        @{
            name = $_.name; local = $_.local; jobs = @($_.jobs | Where-Object { $null -ne $_ })
            counts = Get-StateCounts $_.jobs; updatedAt = $_.updatedAt
            error = $_.error; failingSince = $_.failingSince
        }
    })
    return @{ type = 'jobs'; now = $Now; hosts = $lhost; hostsError = $script:HostsError; alertMs = $AlertMs }
}

function Show-Page([long]$Now) {
    [void](Send-FuyuWebviewMessage $ViewId (Get-PageModel $Now))
}

function Show-Queue([long]$Now) {
    Show-Bar $Now
    Show-Page $Now
}

Invoke-FuyuLoop @{
    initialize = {
        param($params)
        # The island's data folder is two up from the plugin's: <app>\plugins-data\<id>.
        $script:AppDir = Split-Path (Split-Path $params.dataDir -Parent) -Parent
        $script:CanPie = @($params.capabilities) -contains 'statusPie'
        $saved = Get-FuyuStorage 'locale'
        if ($saved) { $script:Locale = [string]$saved }
        # The bar's item is cleared when the plugin stops, so it stays running.
        Set-FuyuKeepAlive 'Shows the Slurm job queue on the collapsed bar'
        Update-Sources
    }
    'webview.message' = {
        param($params)
        if ($params.message.type -ne 'ready') { return }
        $locale = [string]$params.message.locale
        if ($locale -and $locale -ne $script:Locale) {
            $script:Locale = $locale
            Set-FuyuStorage 'locale' $locale
            Show-Bar (Get-Now)
        }
        Show-Page (Get-Now)
    }
} -TimeoutMs $TickMs -OnIdle { Update-Sources }
