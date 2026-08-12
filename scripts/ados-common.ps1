Set-StrictMode -Version 2.0

function Resolve-AdosRepoRoot {
    param([string]$Path)

    $resolved = (Resolve-Path $Path).Path
    Push-Location $resolved
    try {
        $root = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $root) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    }
    finally { Pop-Location }
}

function Ensure-AdosDirectory {
    param([string]$Path)
    if ($Path -and -not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-AdosUtf8 {
    param([string]$Path, [string]$Content)

    Ensure-AdosDirectory (Split-Path -Parent $Path)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-AdosJson {
    param([string]$Path, $Value, [int]$Depth = 12)
    Write-AdosUtf8 $Path ($Value | ConvertTo-Json -Depth $Depth)
}

function Read-AdosJson {
    param([string]$Path, $DefaultValue = $null)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $DefaultValue }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $DefaultValue }
}

function Get-AdosRelativePath {
    param([string]$Root, [string]$FullPath)

    $rootUri = New-Object System.Uri(($Root.TrimEnd('\') + '\'))
    $fileUri = New-Object System.Uri($FullPath)
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fileUri).ToString()).Replace('/', '\')
}

function Get-AdosChangedFiles {
    param([string]$Root)

    Push-Location $Root
    try {
        $files = @()
        $files += @(& git -c core.safecrlf=false diff --name-only 2>$null)
        $files += @(& git -c core.safecrlf=false diff --cached --name-only 2>$null)
        $files += @(& git ls-files --others --exclude-standard 2>$null)
        return @($files | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace('/', '\') } | Sort-Object -Unique)
    }
    finally { Pop-Location }
}

function Get-AdosSourceFiles {
    param([string]$Root, [int]$Limit = 2000, [switch]$IncludeDocs)

    $extensions = @('.ts','.tsx','.js','.jsx','.mjs','.cjs','.py','.ps1','.psm1','.psd1','.rs','.go','.java','.kt','.kts','.cs','.sql')
    if ($IncludeDocs) { $extensions += @('.md','.txt','.json','.yaml','.yml','.toml') }
    $excluded = '(?i)[\\/](node_modules|dist|build|coverage|\.git|\.ai|\.next|\.expo|ios|android|vendor|target|bin|obj)[\\/]'
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $extensions -contains $_.Extension.ToLowerInvariant() -and
            $_.FullName -notmatch $excluded -and
            $_.Length -lt 1000000
        } |
        Sort-Object FullName |
        Select-Object -First $Limit)
}

function Get-AdosTaskTerms {
    param([string]$Text)

    $stop = @(
        'the','and','for','with','from','this','that','into','when','then','fix','fixed',
        'update','updated','change','changed','add','added','remove','removed','error',
        'issue','bug','task','project','code','file','files','please','need','make','check',
        'implement','implementation','improve','using','should','would','could'
    )
    $parts = [regex]::Matches($Text.ToLowerInvariant(), '[\p{L}\p{Nd}_-]{3,}') |
        ForEach-Object { $_.Value }
    return @($parts | Where-Object { $stop -notcontains $_ } | Sort-Object -Unique | Select-Object -First 24)
}

function Get-AdosTextHash {
    param([string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) }
    finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-AdosTaskId {
    param([string]$Task)
    $hash = Get-AdosTextHash $Task
    return $hash.Substring(0, 16)
}

function Get-AdosEvidenceFingerprint {
    param([string]$Root)

    Push-Location $Root
    try {
        $parts = @(
            'HEAD=' + (Get-AdosHead $Root),
            'BRANCH=' + (Get-AdosBranch $Root)
        )
        $changed = @(Get-AdosChangedFiles $Root | Sort-Object)
        foreach ($relative in $changed) {
            $candidate = Join-Path $Root ([string]$relative)
            $gitPath = ([string]$relative).Replace('\', '/')
            $indexState = (& git ls-files -s -- $gitPath 2>$null | Out-String).Trim()
            $worktreeState = 'missing'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                try { $worktreeState = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() }
                catch {
                    $item = Get-Item -LiteralPath $candidate
                    $worktreeState = 'unreadable:' + [string]$item.Length
                }
            }
            $parts += ([string]$relative).Replace('/', '\') + '|index=' + $indexState + '|worktree=' + $worktreeState
        }
        return Get-AdosTextHash ($parts -join "`n")
    }
    finally { Pop-Location }
}

function Get-AdosHead {
    param([string]$Root)
    Push-Location $Root
    try { return ((& git rev-parse HEAD 2>$null | Out-String).Trim()) }
    finally { Pop-Location }
}

function Get-AdosBranch {
    param([string]$Root)
    Push-Location $Root
    try { return ((& git branch --show-current 2>$null | Out-String).Trim()) }
    finally { Pop-Location }
}

function Add-AdosUsageEvent {
    param(
        [string]$Root,
        [string]$Stage,
        [string]$Status,
        [long]$DurationMs = 0,
        [long]$InputBytes = 0,
        [long]$SelectedBytes = 0,
        [hashtable]$Details = @{}
    )

    $path = Join-Path $Root '.ai\analytics\usage-events.json'
    $existing = Read-AdosJson $path $null
    $events = @()
    if ($existing -and $existing.events) { $events = @($existing.events) }
    $events += [pscustomobject]@{
        generated = (Get-Date -Format o)
        stage = $Stage
        status = $Status
        durationMs = $DurationMs
        inputBytes = $InputBytes
        selectedBytes = $SelectedBytes
        details = [pscustomobject]$Details
    }
    if ($events.Count -gt 1000) { $events = @($events | Select-Object -Last 1000) }
    $payload = [ordered]@{ schemaVersion = 1; events = @($events) }
    Write-AdosJson $path $payload 10
}

function ConvertTo-AdosMarkdownList {
    param([object[]]$Items, [string]$EmptyText = 'none')
    $lines = @($Items | ForEach-Object { '- `' + [string]$_ + '`' })
    if ($lines.Count -eq 0) { return @("- $EmptyText") }
    return $lines
}

function Ensure-AdosLocalExclude {
    param([string]$Root)

    Push-Location $Root
    try { $exclude = (& git rev-parse --git-path info/exclude 2>$null | Out-String).Trim() }
    finally { Pop-Location }
    if (-not $exclude) { throw "Unable to resolve Git exclude path for $Root" }
    if (-not [IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path $Root $exclude }
    $exclude = [IO.Path]::GetFullPath($exclude)
    Ensure-AdosDirectory (Split-Path -Parent $exclude)
    $rules = @('.ai/index/','.ai/evidence/','.ai/checkpoints/','.ai/queue/','.ai/memory/','.ai/analytics/','.ai/local-output/','.ai/test-work/','.ai/context/*.generated.json','.ai/context/*.generated.md')
    $existing = if (Test-Path -LiteralPath $exclude) { @(Get-Content -LiteralPath $exclude) } else { @() }
    foreach ($rule in $rules) {
        if ($existing -notcontains $rule) { Add-Content -LiteralPath $exclude -Value $rule -Encoding UTF8 }
    }
}
