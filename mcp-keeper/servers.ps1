$script:Recipes = @(
    @{ id = 'playwright'; package = '@playwright/mcp'; port = 8931 },
    @{ id = 'windows-mcp'; program = 'windows-mcp'; port = 8932 },
    @{ id = 'mobile-mcp'; package = '@mobilenext/mobile-mcp'; port = 8933 }
)

function Get-HttpArgs([string]$RecipeId, [int]$Port) {
    switch ($RecipeId) {
        'playwright' { return @('--host', '127.0.0.1', '--port', "$Port") }
        'mobile-mcp' { return @('--listen', "127.0.0.1:$Port") }
        'windows-mcp' { return @('--transport', 'streamable-http', '--host', '127.0.0.1', '--port', "$Port") }
    }
}

function Get-ServerUrl([int]$Port) { "http://127.0.0.1:$Port/mcp" }

function Get-Leaf([string]$Path) { ($Path -split '[\\/]')[-1] }

function Read-Json([string]$Text) {
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.DeserializeObject($Text)
}

function Write-Json($Value) {
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.Serialize($Value)
}

function Get-ClaudeJsonPath {
    if ($env:MCP_KEEPER_CLAUDE_JSON) { return $env:MCP_KEEPER_CLAUDE_JSON }
    Join-Path $env:USERPROFILE '.claude.json'
}

function Get-McpServers {
    $path = Get-ClaudeJsonPath
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    $data = Read-Json ([IO.File]::ReadAllText($path))
    if ($null -eq $data -or -not $data.ContainsKey('mcpServers') -or $null -eq $data['mcpServers']) { return @{} }
    $data['mcpServers']
}

function Get-Kind($Config) {
    $type = if ($Config.ContainsKey('type')) { [string]$Config['type'] } else { '' }
    if ($Config.ContainsKey('url') -or $type -eq 'http' -or $type -eq 'sse') { return 'url' }
    if ($Config.ContainsKey('command')) { return 'stdio' }
    'other'
}

function Find-NpmEntry([string]$Package, [string]$Version) {
    $relative = 'node_modules\' + ($Package -replace '/', '\')
    $roots = @()
    if ($env:APPDATA) { $roots += Join-Path $env:APPDATA 'npm' }
    if ($env:LOCALAPPDATA) { $roots += @(Get-ChildItem -Directory -ErrorAction SilentlyContinue (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx') | ForEach-Object { $_.FullName }) }
    $found = @()
    foreach ($root in $roots) {
        $dir = Join-Path $root $relative
        $manifest = Join-Path $dir 'package.json'
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        $info = Read-Json ([IO.File]::ReadAllText($manifest))
        $bin = $info['bin']
        if ($bin -is [string]) { $entry = $bin } elseif ($bin -is [System.Collections.IDictionary] -and $bin.Count -gt 0) { $entry = @($bin.Values)[0] } else { continue }
        $path = Join-Path $dir $entry
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $parsed = $null
        if (-not [version]::TryParse(($info['version'] -replace '[-+].*$', ''), [ref]$parsed)) { continue }
        $found += @{ path = $path; version = [string]$info['version']; parsed = $parsed }
    }
    $wanted = @($found | Where-Object { -not $Version -or $Version -eq 'latest' -or $_.version -eq $Version })
    if ($wanted.Count -eq 0) { return $null }
    (@($wanted | Sort-Object { $_.parsed } -Descending))[0].path
}

function Get-NodePath {
    $node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($node) { $node.Source } else { $null }
}

function Get-Launch($Config, [int]$Port = 0) {
    if ((Get-Kind $Config) -ne 'stdio') { return $null }
    $words = @([string]$Config['command']) + @($Config['args'] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    if ($words.Count -ge 2 -and (Get-Leaf $words[0]) -match '^cmd(\.exe)?$' -and $words[1] -match '^/[cC]$') { $words = @($words[2..($words.Count - 1)]) }
    foreach ($recipe in $script:Recipes) {
        $at = -1; $version = $null
        for ($i = 0; $i -lt $words.Count; $i++) {
            if ($recipe.package -and $words[$i] -match ('^' + [regex]::Escape($recipe.package) + '(@(.+))?$')) { $at = $i; $version = $Matches[2]; break }
            if ($recipe.program -and (Get-Leaf $words[$i]) -match ('^' + [regex]::Escape($recipe.program) + '(\.exe)?$')) { $at = $i; break }
        }
        if ($at -lt 0) { continue }
        $rest = if ($at + 1 -lt $words.Count) { @($words[($at + 1)..($words.Count - 1)]) } else { @() }
        $port = if ($Port -gt 0) { $Port } else { $recipe.port + [int]$env:MCP_KEEPER_PORT_OFFSET }
        if ($recipe.package) {
            $entry = Find-NpmEntry $recipe.package $version
            $node = Get-NodePath
            if ($entry -and $node) { $command = $node; $argv = @($entry) + $rest }
            else { $command = $words[0]; $argv = @($words[1..$at]) + $rest }
        } else {
            $command = $words[0]
            $argv = if ($at -eq 0) { $rest } else { @($words[1..$at]) + $rest }
            if ($argv -notcontains 'serve') { $argv = @('serve') + $argv }
        }
        $vars = @{}
        if ($Config.ContainsKey('env') -and $Config['env'] -is [System.Collections.IDictionary]) { foreach ($key in $Config['env'].Keys) { $vars[$key] = [string]$Config['env'][$key] } }
        return @{ recipe = $recipe.id; port = $port; command = $command; args = @($argv) + @(Get-HttpArgs $recipe.id $port); env = $vars }
    }
    $null
}

function Format-NativeArg([string]$Arg) {
    if ($Arg -ne '' -and $Arg -notmatch '[\s"]') { return $Arg }
    $out = '"'; $slashes = 0
    foreach ($c in $Arg.ToCharArray()) {
        if ($c -eq '\') { $slashes++; continue }
        if ($c -eq '"') { $out += ('\' * (2 * $slashes + 1)) + '"' } else { $out += ('\' * $slashes) + $c }
        $slashes = 0
    }
    $out + ('\' * (2 * $slashes)) + '"'
}

function New-HiddenStart([string]$FileName, [string]$Arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FileName
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info
}

function Invoke-Native([string]$FileName, [string[]]$Arguments, [int]$TimeoutMs = 60000) {
    $info = New-HiddenStart $FileName ((@($Arguments) | ForEach-Object { Format-NativeArg $_ }) -join ' ')
    $process = [System.Diagnostics.Process]::Start($info)
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMs)) { try { $process.Kill() } catch {}; return @{ code = -1; output = 'timed out' } }
    $process.WaitForExit()
    @{ code = $process.ExitCode; output = ($out.Result + $err.Result).Trim() }
}

function Get-ClaudeCommand {
    if ($env:MCP_KEEPER_CLAUDE) { return @{ file = $env:MCP_KEEPER_CLAUDE; prefix = @($env:MCP_KEEPER_CLAUDE_ARGS -split '\|' | Where-Object { $_ }) } }
    $local = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $local) { return @{ file = $local; prefix = @() } }
    $found = Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { @{ file = $found.Source; prefix = @() } } else { $null }
}

function Set-UserMcp([string]$Name, [string]$Json) {
    $claude = Get-ClaudeCommand
    if (-not $claude) { throw 'claude.exe not found' }
    $null = Invoke-Native $claude.file (@($claude.prefix) + @('mcp', 'remove', '-s', 'user', $Name))
    $added = Invoke-Native $claude.file (@($claude.prefix) + @('mcp', 'add-json', '-s', 'user', $Name, $Json))
    if ($added.code -ne 0) { throw "claude mcp add-json failed: $($added.output)" }
}

function Test-Listening([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.ConnectAsync('127.0.0.1', $Port).Wait(300) -and $client.Connected } catch { $false } finally { $client.Close() }
}

function Get-PortOwner([int]$Port) {
    $owner = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $owner) { return $null }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($owner.OwningProcess)" -ErrorAction SilentlyContinue
    if ($process) { @{ id = [int]$process.ProcessId; commandLine = [string]$process.CommandLine } } else { @{ id = [int]$owner.OwningProcess; commandLine = '' } }
}

function Stop-Tree([int]$ProcessId) {
    $null = Invoke-Native (Join-Path $env:SystemRoot 'System32\taskkill.exe') @('/PID', "$ProcessId", '/T', '/F') 10000
}

function Clear-Port($Launch) {
    if (-not (Test-Listening $Launch.port)) { return $true }
    $owner = Get-PortOwner $Launch.port
    $recipe = $script:Recipes | Where-Object { $_.id -eq $Launch.recipe }
    $mark = if ($recipe.package) { $recipe.package } else { $recipe.program }
    if (-not $owner -or $owner.commandLine.Replace('\', '/').IndexOf($mark, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    Stop-Tree $owner.id
    for ($i = 0; $i -lt 20 -and (Test-Listening $Launch.port); $i++) { Start-Sleep -Milliseconds 250 }
    -not (Test-Listening $Launch.port)
}

function Start-Server($Launch, [string]$LogPath) {
    foreach ($word in @($Launch.command) + $Launch.args + @($LogPath)) { if ($word -match '["%]') { throw "unsupported character in: $word" } }
    $line = (@($Launch.command) + $Launch.args | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info = New-HiddenStart $env:ComSpec ('/d /s /c "' + $line + ' < NUL > "' + $LogPath + '" 2>&1"')
    foreach ($key in $Launch.env.Keys) { $info.EnvironmentVariables[$key] = $Launch.env[$key] }
    [System.Diagnostics.Process]::Start($info)
}
