# What the job-queue plugin asks and how it reads the answers, with no island and no processes:
# main.ps1 and the tests dot-source it. ASCII only, like main.ps1.

# The page's fields in squeue's order. The working directory comes last so that a '|' in it
# stays in it.
# shortcut: a '|' in a job name shifts the fields after it; move to squeue --json (Slurm 21.08+) if that bites.
$SqueueFields = @('id', 'state', 'name', 'elapsed', 'limit', 'partition', 'nodes', 'cpus', 'gres', 'submit', 'start', 'reason', 'workdir')
$SqueueFormat = '%i|%t|%j|%M|%l|%P|%D|%C|%b|%V|%S|%R|%Z'
# squeue's answer starts after this line, so whatever a login script prints is skipped.
$SqueueMarker = '__fuyu_squeue__'
# What the WSL shell exits with when it has no squeue: no Slurm there, which is not a failure.
$NoSqueueExit = 99
# The states with their own slice; every other one (CF, S, ST, ...) counts as "other".
$MainStates = @('R', 'PD', 'CG')

# The script sent on the shell's stdin. ssh starts the login shell, so the user's PATH and
# modules are set as when they log in; backticks rather than $(...) in case that shell is csh.
function Get-SqueueScript([bool]$Local) {
    # A leading empty line: should a BOM come first, it is a harmless line of its own.
    $lline = @("")
    if ($Local) { $lline += "command -v squeue >/dev/null 2>&1 || exit $NoSqueueExit" }
    $lline += "echo $SqueueMarker"
    $lline += "squeue -h -u ``id -un`` -o '$SqueueFormat'"
    return ($lline -join "`n") + "`n"
}

function Test-SshWord([string]$Word) {
    return $Word -match '^[A-Za-z0-9._@:-]{1,253}$' -and -not $Word.StartsWith('-')
}

# The computers ticked in the island under Settings > AI Agent > Remote computers, in its order,
# as @{ name; args } for ssh. Not a plugin API: the island's own file, which it validates too.
# No file means nothing is ticked; a file that is not JSON throws.
function Get-RemoteHosts([string]$AppDir) {
    $path_hosts = Join-Path $AppDir 'agent-remote-hosts.json'
    if (-not (Test-Path -LiteralPath $path_hosts)) { return @() }
    $file = [IO.File]::ReadAllText($path_hosts) | ConvertFrom-Json
    $dict_custom = @{}
    foreach ($custom in @($file.custom)) {
        if ($null -ne $custom -and $custom.name) { $dict_custom[[string]$custom.name] = $custom }
    }
    $lhost = @()
    foreach ($name in @($file.hosts)) {
        $name = [string]$name
        if (-not (Test-SshWord $name)) { continue }
        $largs = @()
        $destination = $name
        $custom = $dict_custom[$name]
        if ($null -ne $custom) {
            # Added in the island by address: ssh -p <port> <user>@<host>.
            if (-not (Test-SshWord ([string]$custom.host))) { continue }
            $destination = [string]$custom.host
            if ($custom.user) {
                if (-not (Test-SshWord ([string]$custom.user))) { continue }
                $destination = "$($custom.user)@$destination"
            }
            if ($custom.port) { $largs += @('-p', [string][int]$custom.port) }
        }
        $lhost += @{ name = $name; args = @($largs + @('--', $destination)) }
    }
    return $lhost
}

# The jobs in a shell's output, or $null when the marker never came (the shell died first).
function ConvertFrom-SqueueOutput([string]$Text) {
    $llines = @($Text -split "`r?`n")
    $start = [Array]::IndexOf($llines, $SqueueMarker)
    if ($start -lt 0) { return $null }
    $ljob = @()
    for ($index = $start + 1; $index -lt $llines.Count; $index++) {
        $lpart = @($llines[$index] -split '\|', $SqueueFields.Count)
        if ($lpart.Count -lt $SqueueFields.Count) { continue }
        $job = @{}
        for ($field = 0; $field -lt $SqueueFields.Count; $field++) { $job[$SqueueFields[$field]] = $lpart[$field].Trim() }
        $ljob += $job
    }
    # The comma keeps an empty queue an empty array: PowerShell would unroll it to $null, a failure.
    return ,$ljob
}

# @{ R; PD; CG; other } over every job given.
function Get-StateCounts($Jobs) {
    $dict_count = @{ R = 0; PD = 0; CG = 0; other = 0 }
    foreach ($job in @($Jobs)) {
        if ($null -eq $job) { continue }
        if ($MainStates -contains $job.state) { $dict_count[$job.state]++ } else { $dict_count.other++ }
    }
    return $dict_count
}

# The last line a failed shell said that explains it, without ssh's post-quantum warning.
function Get-FailureReason([string]$Stderr, [int]$ExitCode) {
    $lline = @($Stderr -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.StartsWith('**') })
    if ($lline.Count -gt 0) { return $lline[-1].Trim() }
    return "exit code $ExitCode"
}
