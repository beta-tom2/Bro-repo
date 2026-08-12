[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('record','summary')]
    [string]$Action,
    [string]$ProjectPath='.',
    [string]$Task='',
    [string[]]$Skills=@(),
    [ValidateSet('selected','completed','failed','skipped','rolled-back','unknown')]
    [string]$Outcome='unknown',
    [ValidateRange(0,5)]
    [int]$Benefit=0,
    [ValidateRange(0,5)]
    [int]$Cost=0,
    [string]$Notes=''
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot([string]$Path) {
    $resolved = (Resolve-Path $Path).Path
    Push-Location $resolved
    try {
        $root = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $root) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($root)
    }
    finally { Pop-Location }
}

function Write-Utf8NoBom([string]$Path,[string]$Content) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

$root = Resolve-RepoRoot $ProjectPath
$telemetryDir = Join-Path $root '.ai\analytics'
$telemetryPath = Join-Path $telemetryDir 'skill-telemetry.jsonl'

if ($Action -eq 'record') {
    if (-not $Task) { throw 'Task is required for record.' }
    if (-not (Test-Path $telemetryDir)) { New-Item -ItemType Directory -Path $telemetryDir -Force | Out-Null }

    $branch = ''
    $head = ''
    Push-Location $root
    try {
        $branch = (& git branch --show-current | Out-String).Trim()
        $head = (& git rev-parse HEAD | Out-String).Trim()
    }
    finally { Pop-Location }

    $entry = [ordered]@{
        timestamp = (Get-Date -Format o)
        project = (Split-Path $root -Leaf)
        repository = $root
        branch = $branch
        head = $head
        task = $Task
        skills = @($Skills | Where-Object { $_ } | Sort-Object -Unique)
        outcome = $Outcome
        benefit = $Benefit
        cost = $Cost
        net = ($Benefit - $Cost)
        notes = $Notes
    }

    $line = $entry | ConvertTo-Json -Compress -Depth 5
    [IO.File]::AppendAllText($telemetryPath,($line + [Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    Write-Host "Recorded skill telemetry: $telemetryPath"
    return
}

if (-not (Test-Path $telemetryPath)) {
    Write-Host 'No skill telemetry recorded for this project.'
    return
}

$rows = @()
foreach ($line in (Get-Content -LiteralPath $telemetryPath -ErrorAction Stop)) {
    if (-not $line.Trim()) { continue }
    try { $rows += ($line | ConvertFrom-Json) } catch { }
}

if ($rows.Count -eq 0) {
    Write-Host 'No valid skill telemetry records found.'
    return
}

$stats = @{}
foreach ($row in $rows) {
    foreach ($skill in @($row.skills)) {
        if (-not $stats.ContainsKey($skill)) {
            $stats[$skill] = [ordered]@{ skill=$skill; uses=0; completed=0; failed=0; benefit=0; cost=0; net=0 }
        }
        $s = $stats[$skill]
        $s.uses++
        if ($row.outcome -eq 'completed') { $s.completed++ }
        if ($row.outcome -eq 'failed' -or $row.outcome -eq 'rolled-back') { $s.failed++ }
        $s.benefit += [int]$row.benefit
        $s.cost += [int]$row.cost
        $s.net += [int]$row.net
    }
}

$stats.Values |
    Sort-Object @{Expression='net';Descending=$true}, @{Expression='uses';Descending=$true} |
    Format-Table skill,uses,completed,failed,benefit,cost,net -AutoSize
