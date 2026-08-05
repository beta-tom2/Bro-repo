[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('heatmap','graph','fixdna','all')]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [string]$Task = '',
    [int]$MaxCommits = 300,
    [int]$MaxFiles = 400
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
    param([string]$Path)
    $resolved = (Resolve-Path $Path).Path
    Push-Location $resolved
    try {
        $root = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $root) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($root).TrimEnd('\','/')
    }
    finally { Pop-Location }
}

function Ensure-Directory {
    param([string]$Path)
    if ($Path) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    Ensure-Directory (Split-Path -Parent $Path)
    [IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))
}

function Relative-Path {
    param([string]$Root,[string]$FullPath)
    $rootUri = New-Object System.Uri(($Root.TrimEnd('\') + '\'))
    $fileUri = New-Object System.Uri($FullPath)
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fileUri).ToString()).Replace('/','\')
}

function Normalize-Terms {
    param([string]$Text)
    $stop = @('the','and','for','with','from','this','that','into','when','then','fix','fixed','update','updated','change','changed','add','added','remove','removed','error','issue','bug','task','project','code','file','files','please','need','make')
    $parts = [regex]::Matches($Text.ToLowerInvariant(),'[a-z0-9_\-]{3,}') | ForEach-Object { $_.Value }
    return @($parts | Where-Object { $stop -notcontains $_ } | Sort-Object -Unique)
}

function Invoke-HeatMap {
    param([string]$Root,[int]$Limit)
    Push-Location $Root
    try {
        $raw = & git log -n $Limit --date=iso-strict --pretty=format:'@@@%H|%ad' --name-only
        $scores = @{}
        $currentDate = Get-Date
        $commitDate = $null
        foreach ($line in $raw) {
            if ($line -like '@@@*') {
                $parts = $line.Substring(3).Split('|',2)
                if ($parts.Count -eq 2) { $commitDate = [datetime]$parts[1] }
                continue
            }
            if (-not $line -or -not $commitDate) { continue }
            $path = $line.Replace('/','\')
            $segments = $path.Split('\')
            $area = if ($segments.Count -gt 1) { $segments[0] + '\' + $segments[1] } else { $segments[0] }
            $ageDays = [math]::Max(0,($currentDate - $commitDate).TotalDays)
            $recency = [math]::Max(1,30 - [math]::Min(29,[int]$ageDays))
            if (-not $scores.ContainsKey($area)) {
                $scores[$area] = [pscustomobject]@{ Area=$area; Changes=0; Recency=0; Score=0 }
            }
            $scores[$area].Changes++
            $scores[$area].Recency += $recency
            $scores[$area].Score = ($scores[$area].Changes * 3) + $scores[$area].Recency
        }

        $ranked = @($scores.Values | Sort-Object -Property @{Expression='Score';Descending=$true}, @{Expression='Changes';Descending=$true} | Select-Object -First 60)
        $lines = New-Object Collections.Generic.List[string]
        $lines.Add('# ADOS project heat map')
        $lines.Add('')
        $lines.Add("Generated: $(Get-Date -Format o)")
        $lines.Add("Commits sampled: $Limit")
        $lines.Add('')
        $lines.Add('| Rank | Area | Changes | Recency | Heat |')
        $lines.Add('|---:|---|---:|---:|---:|')
        $rank = 1
        foreach ($item in $ranked) {
            $lines.Add("| $rank | ``$($item.Area)`` | $($item.Changes) | $($item.Recency) | $($item.Score) |")
            $rank++
        }
        if ($ranked.Count -eq 0) { $lines.Add('| 1 | none | 0 | 0 | 0 |') }
        $output = Join-Path $Root '.ai\analytics\heat-map.generated.md'
        Write-Utf8NoBom $output ($lines -join "`r`n")
        Write-Host "Heat map written to $output"
    }
    finally { Pop-Location }
}

function Invoke-Graph {
    param([string]$Root,[int]$Limit)
    $extensions = @('.ts','.tsx','.js','.jsx','.mjs','.cjs','.py')
    $excluded = '(?i)[\\/](node_modules|dist|build|coverage|\.git|\.ai|\.next|\.expo|ios|android|vendor)[\\/]'
    $files = @(Get-ChildItem $Root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch $excluded -and $_.Length -lt 300000 } |
        Sort-Object FullName | Select-Object -First $Limit)

    $nodes = New-Object Collections.Generic.HashSet[string]
    $edges = New-Object Collections.Generic.List[object]
    foreach ($file in $files) {
        $relative = Relative-Path $Root $file.FullName
        $null = $nodes.Add($relative)
        foreach ($line in (Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
            $target = $null
            if ($line -match '^\s*import\s+.*?from\s+["'']([^"'']+)["'']' -or $line -match '^\s*import\s+["'']([^"'']+)["'']' -or $line -match 'require\(["'']([^"'']+)["'']\)') {
                $target = $Matches[1]
            }
            elseif ($file.Extension -eq '.py' -and ($line -match '^\s*from\s+([A-Za-z0-9_\.]+)\s+import' -or $line -match '^\s*import\s+([A-Za-z0-9_\.]+)')) {
                $target = $Matches[1]
            }
            if ($target) {
                $edges.Add([pscustomobject]@{ Source=$relative; Target=$target })
            }
        }
    }

    $payload = [pscustomobject]@{
        generated = (Get-Date -Format o)
        repository = $Root
        nodes = @($nodes)
        edges = @($edges)
    }
    $jsonPath = Join-Path $Root '.ai\analytics\knowledge-graph.generated.json'
    Write-Utf8NoBom $jsonPath ($payload | ConvertTo-Json -Depth 6)

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# ADOS knowledge graph summary')
    $lines.Add('')
    $lines.Add("Generated: $(Get-Date -Format o)")
    $lines.Add("Nodes: $($nodes.Count)")
    $lines.Add("Edges: $($edges.Count)")
    $lines.Add('')
    $lines.Add('## Most connected sources')
    $grouped = @($edges | Group-Object Source | Sort-Object Count -Descending | Select-Object -First 40)
    foreach ($group in $grouped) { $lines.Add("- ``$($group.Name)`` -> $($group.Count) imports") }
    if ($grouped.Count -eq 0) { $lines.Add('- none') }
    $summaryPath = Join-Path $Root '.ai\analytics\knowledge-graph.generated.md'
    Write-Utf8NoBom $summaryPath ($lines -join "`r`n")
    Write-Host "Knowledge graph written to $jsonPath"
}

function Invoke-FixDna {
    param([string]$Root,[string]$TaskText)
    if (-not $TaskText) { throw 'Task is required for fixdna.' }
    Push-Location $Root
    try {
        $changed = @()
        $changed += (& git diff --name-only)
        $changed += (& git diff --cached --name-only)
        $changed += (& git ls-files --others --exclude-standard)
        $changed = @($changed | Where-Object { $_ } | Sort-Object -Unique)
        $terms = Normalize-Terms $TaskText
        $domains = New-Object Collections.Generic.List[string]
        $rules = @{
            auth='auth|login|session|permission|role';
            database='sql|migration|supabase|database|rls';
            social='friend|contact|invite|social|people';
            ui='screen|component|layout|style|copy|accessibility';
            release='build|apk|aab|eas|deploy|release';
            trading='trade|broker|order|risk|loss|portfolio';
            docs='readme|documentation|changelog|guide'
        }
        foreach ($key in $rules.Keys) {
            if ($TaskText -match ('(?i)' + $rules[$key])) { $domains.Add($key) }
        }
        foreach ($file in $changed) {
            foreach ($key in $rules.Keys) {
                if ($file -match ('(?i)' + $rules[$key]) -and $domains -notcontains $key) { $domains.Add($key) }
            }
        }
        $route = if ($TaskText -match '(?i)auth|security|rls|sql|migration|production|release|payment|broker|trading|financial|secret|credential|deploy|architecture|dependency|native|permission|encryption') { 'CODEX_REQUIRED' } elseif ($TaskText -match '(?i)readme|documentation|summary|wording|typo|naming|duplicate|todo|comment|log|boilerplate|changelog') { 'LOCAL_FIRST_THEN_CODEX_VERIFY' } else { 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS' }
        $dna = [pscustomobject]@{
            generated = (Get-Date -Format o)
            task = $TaskText
            route = $route
            terms = @($terms)
            domains = @($domains | Sort-Object -Unique)
            changedFiles = $changed
            branch = ((& git branch --show-current | Out-String).Trim())
            commit = ((& git rev-parse HEAD | Out-String).Trim())
        }
        $jsonPath = Join-Path $Root '.ai\context\fix-dna.generated.json'
        Write-Utf8NoBom $jsonPath ($dna | ConvertTo-Json -Depth 6)
        $md = @"
# ADOS Fix DNA

Generated: $($dna.generated)
Route: $($dna.route)

## Task
$TaskText

## Terms
$((@($dna.terms) | ForEach-Object { '- `' + $_ + '`' }) -join "`r`n")

## Domains
$((@($dna.domains) | ForEach-Object { '- `' + $_ + '`' }) -join "`r`n")

## Changed files
$((if ($changed.Count) { ($changed | ForEach-Object { '- `' + $_ + '`' }) -join "`r`n" } else { '- none' }))
"@
        $mdPath = Join-Path $Root '.ai\context\fix-dna.generated.md'
        Write-Utf8NoBom $mdPath $md
        Write-Host "Fix DNA written to $jsonPath"
    }
    finally { Pop-Location }
}

$root = Resolve-RepoRoot $ProjectPath
switch ($Command) {
    'heatmap' { Invoke-HeatMap $root $MaxCommits }
    'graph' { Invoke-Graph $root $MaxFiles }
    'fixdna' { Invoke-FixDna $root $Task }
    'all' {
        Invoke-HeatMap $root $MaxCommits
        Invoke-Graph $root $MaxFiles
        if ($Task) { Invoke-FixDna $root $Task }
    }
}
