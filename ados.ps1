[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('doctor','start','analyze','night','handoff')]
    [string]$Command,

    [string]$ProjectPath = '.',
    [string]$Task = '',
    [int]$ContextBudgetBytes = 160000,
    [int]$MaxCommits = 300,
    [int]$MaxFiles = 400
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DevCore = Join-Path $Root 'devcore.ps1'
$Memory = Join-Path $Root 'scripts\devcore-memory.ps1'
$Insights = Join-Path $Root 'scripts\ados-insights.ps1'
$Night = Join-Path $Root 'scripts\ados-night-audit.ps1'

function Require-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Required ADOS component is missing: $Path" }
}

function Resolve-RepoRoot {
    param([string]$Path)
    $resolved = (Resolve-Path $Path).Path
    Push-Location $resolved
    try {
        $repo = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $repo) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($repo).TrimEnd('\','/')
    }
    finally { Pop-Location }
}

function Ensure-LocalExclude {
    param([string]$Repo)
    $exclude = Join-Path $Repo '.git\info\exclude'
    $rules = @(
        '.ai/memory/',
        '.ai/analytics/',
        '.ai/context/session-context.md',
        '.ai/context/repo-map.generated.md',
        '.ai/context/import-map.generated.md',
        '.ai/context/test-plan.generated.md',
        '.ai/context/prompt-packet.generated.md',
        '.ai/context/similar-repairs.generated.md',
        '.ai/context/handoff.generated.md',
        '.ai/context/fix-dna.generated.json',
        '.ai/context/fix-dna.generated.md',
        '.ai/local-output/'
    )
    $existing = if (Test-Path $exclude) { @(Get-Content $exclude) } else { @() }
    foreach ($rule in $rules) {
        if ($existing -notcontains $rule) { Add-Content -Path $exclude -Value $rule -Encoding UTF8 }
    }
}

function Invoke-Doctor {
    Require-File $DevCore
    Require-File $Memory
    Require-File $Insights
    Require-File $Night
    & $DevCore doctor
    Write-Host ''
    Write-Host 'ADOS components:'
    Write-Host ('{0,-28} PASS' -f 'devcore')
    Write-Host ('{0,-28} PASS' -f 'repair memory')
    Write-Host ('{0,-28} PASS' -f 'heat map / graph / fix dna')
    Write-Host ('{0,-28} PASS' -f 'night audit')
}

function Invoke-Analyze {
    param([string]$Repo,[string]$TaskText)
    Ensure-LocalExclude $Repo
    & $DevCore update -ProjectPath $Repo
    & $Memory index -ProjectPath $Repo -MaxCommits $MaxCommits
    & $Insights all -ProjectPath $Repo -Task $TaskText -MaxCommits $MaxCommits -MaxFiles $MaxFiles
    if ($TaskText) {
        & $Memory search -ProjectPath $Repo -Query $TaskText -MaxCommits $MaxCommits
        & $DevCore packet -ProjectPath $Repo -Task $TaskText -ContextBudgetBytes $ContextBudgetBytes
    }
    Write-Host "ADOS analysis completed for $Repo"
}

function Invoke-Start {
    param([string]$Repo,[string]$TaskText)
    if (-not $TaskText) { throw 'Task is required for start.' }
    Ensure-LocalExclude $Repo
    $route = (& $DevCore route -Task $TaskText | Out-String).Trim()
    Write-Host "Route: $route"
    & $DevCore update -ProjectPath $Repo
    & $Memory index -ProjectPath $Repo -MaxCommits $MaxCommits
    & $Memory search -ProjectPath $Repo -Query $TaskText -MaxCommits $MaxCommits
    & $Insights heatmap -ProjectPath $Repo -MaxCommits $MaxCommits
    & $Insights fixdna -ProjectPath $Repo -Task $TaskText
    & $DevCore packet -ProjectPath $Repo -Task $TaskText -ContextBudgetBytes $ContextBudgetBytes
    & $Memory handoff -ProjectPath $Repo

    $packet = Join-Path $Repo '.ai\context\prompt-packet.generated.md'
    $dna = Join-Path $Repo '.ai\context\fix-dna.generated.md'
    $similar = Join-Path $Repo '.ai\context\similar-repairs.generated.md'
    $handoff = Join-Path $Repo '.ai\context\handoff.generated.md'

    Write-Host ''
    Write-Host 'ADOS task workspace is ready:'
    Write-Host "  Route: $route"
    Write-Host "  Prompt packet: $packet"
    Write-Host "  Fix DNA: $dna"
    Write-Host "  Similar repairs: $similar"
    Write-Host "  Handoff: $handoff"
    Write-Host ''
    if ($route -eq 'LOCAL_FIRST_THEN_CODEX_VERIFY') {
        Write-Host 'Recommended execution: bounded Ollama first pass, then Codex verification.'
    }
    elseif ($route -eq 'CODEX_REQUIRED') {
        Write-Host 'Recommended execution: Codex only for decisions and code changes; use deterministic checks first.'
    }
    else {
        Write-Host 'Recommended execution: deterministic tools plus Codex, with local read-only review after the diff exists.'
    }
}

$repo = if ($Command -eq 'doctor') { $null } else { Resolve-RepoRoot $ProjectPath }

switch ($Command) {
    'doctor' { Invoke-Doctor }
    'start' { Invoke-Start $repo $Task }
    'analyze' { Invoke-Analyze $repo $Task }
    'night' {
        Ensure-LocalExclude $repo
        & $Insights heatmap -ProjectPath $repo -MaxCommits $MaxCommits
        & $Insights graph -ProjectPath $repo -MaxFiles $MaxFiles
        & $Night -ProjectPath $repo
    }
    'handoff' {
        Ensure-LocalExclude $repo
        & $Memory handoff -ProjectPath $repo
    }
}
