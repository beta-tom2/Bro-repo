[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('doctor','adopt','update','route','local','review')]
    [string]$Command,

    [string]$ProjectPath = '.',
    [string]$Task = '',
    [string[]]$Files = @(),
    [string]$Model = 'qwen2.5-coder:7b'
)

$ErrorActionPreference = 'Stop'
$DevCoreRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-RepositoryRoot {
    param([string]$Path)
    $resolved = (Resolve-Path $Path).Path
    Push-Location $resolved
    try {
        $root = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $root) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($root).TrimEnd('\','/')
    } finally { Pop-Location }
}

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Doctor {
    $checks = @(
        @{ Name='git'; Required=$true; Present=(Test-CommandAvailable 'git') },
        @{ Name='rg'; Required=$true; Present=(Test-CommandAvailable 'rg') },
        @{ Name='ollama'; Required=$false; Present=(Test-CommandAvailable 'ollama') },
        @{ Name='node'; Required=$false; Present=(Test-CommandAvailable 'node') },
        @{ Name='npm'; Required=$false; Present=(Test-CommandAvailable 'npm') }
    )
    foreach ($check in $checks) {
        $status = if ($check.Present) { 'PASS' } elseif ($check.Required) { 'FAIL' } else { 'OPTIONAL-MISSING' }
        Write-Host ('{0,-18} {1}' -f $check.Name, $status)
    }
    if (Test-CommandAvailable 'ollama') {
        Write-Host "`nLocal models:"
        & ollama list
    }
}

function Ensure-Directory {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Copy-IfMissing {
    param([string]$Source,[string]$Destination)
    if (-not (Test-Path $Destination)) {
        Ensure-Directory (Split-Path -Parent $Destination)
        Copy-Item $Source $Destination
        Write-Host "Added: $Destination"
    } else {
        Write-Host "Preserved existing: $Destination"
    }
}

function Invoke-Adopt {
    param([string]$Path)
    $root = Resolve-RepositoryRoot $Path
    $template = Join-Path $DevCoreRoot 'template'
    Copy-IfMissing (Join-Path $template 'AGENTS.md') (Join-Path $root 'AGENTS.md')
    Copy-IfMissing (Join-Path $template '.ai\context\current-state.md') (Join-Path $root '.ai\context\current-state.md')
    Copy-IfMissing (Join-Path $template '.ai\context\decisions.md') (Join-Path $root '.ai\context\decisions.md')
    Copy-IfMissing (Join-Path $template '.ai\LOCAL_MODEL_POLICY.md') (Join-Path $root '.ai\LOCAL_MODEL_POLICY.md')
    Copy-IfMissing (Join-Path $template 'scripts\ai-local-task.ps1') (Join-Path $root 'scripts\ai-local-task.ps1')

    $ignore = Join-Path $root '.gitignore'
    $required = @('.ai/context/session-context.md','.ai/context/repo-map.generated.md','.ai/local-output/','.ai/cache/','*.local-ai.log')
    $existing = if (Test-Path $ignore) { Get-Content $ignore } else { @() }
    foreach ($line in $required) {
        if ($existing -notcontains $line) { Add-Content -Path $ignore -Value $line -Encoding UTF8 }
    }
    Invoke-Update $root
}

function Get-RelativePathCompat {
    param([string]$Root,[string]$FullPath)
    $rootUri = New-Object System.Uri(($Root.TrimEnd('\') + '\'))
    $fileUri = New-Object System.Uri($FullPath)
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fileUri).ToString()).Replace('/','\')
}

function Invoke-Update {
    param([string]$Path)
    $root = Resolve-RepositoryRoot $Path
    Push-Location $root
    try {
        Ensure-Directory (Join-Path $root '.ai\context')
        $branch = (& git branch --show-current | Out-String).Trim()
        $head = (& git rev-parse HEAD | Out-String).Trim()
        $status = (& git status --short | Out-String).TrimEnd()
        $diff = (& git diff --stat | Out-String).TrimEnd()
        $recent = (& git log -n 12 --pretty=format:'%h %ad %s' --date=short | Out-String).TrimEnd()

        $exclude = @('.git','node_modules','dist','build','.next','.expo','coverage','.ai','ios','android')
        $dirs = Get-ChildItem $root -Directory -Force | Where-Object { $exclude -notcontains $_.Name } | Sort-Object Name
        $files = Get-ChildItem $root -File -Force | Where-Object { $_.Length -lt 200000 } | Sort-Object Name

        $map = New-Object Collections.Generic.List[string]
        $map.Add('# Generated repository map')
        $map.Add('')
        $map.Add("Generated: $(Get-Date -Format o)")
        $map.Add("Commit: $head")
        $map.Add('')
        $map.Add('## Top-level directories')
        foreach ($dir in $dirs) { $map.Add("- ``$($dir.Name)/``") }
        $map.Add('')
        $map.Add('## Top-level files')
        foreach ($file in $files) { $map.Add("- ``$($file.Name)`` ($($file.Length) bytes)") }

        $known = @('package.json','pyproject.toml','Cargo.toml','go.mod','README.md','AGENTS.md','App.tsx','src','supabase','docs')
        $map.Add('')
        $map.Add('## Detected entry points')
        foreach ($item in $known) { if (Test-Path (Join-Path $root $item)) { $map.Add("- ``$item``") } }
        [IO.File]::WriteAllLines((Join-Path $root '.ai\context\repo-map.generated.md'),$map,[Text.UTF8Encoding]::new($false))

        $ctx = @"
# Session context

Generated: $(Get-Date -Format o)
Branch: $branch
Commit: $head

## Working tree
```text
$(if ($status) { $status } else { 'clean' })
```

## Diff summary
```text
$(if ($diff) { $diff } else { 'none' })
```

## Recent commits
```text
$recent
```

## Read order
1. AGENTS.md
2. README.md
3. .ai/context/current-state.md
4. .ai/context/decisions.md
5. .ai/context/repo-map.generated.md
6. changed files and focused tests
"@
        [IO.File]::WriteAllText((Join-Path $root '.ai\context\session-context.md'),$ctx,[Text.UTF8Encoding]::new($false))
        Write-Host "Updated DevCore context for $root"
    } finally { Pop-Location }
}

function Invoke-Route {
    param([string]$TaskText)
    if (-not $TaskText) { throw 'Task is required for route.' }
    $highRisk = '(?i)auth|security|rls|sql|migration|production|release|payment|broker|trading|financial|secret|credential|deploy|architecture|refactor.*multiple|dependency|native'
    $localSafe = '(?i)readme|documentation|summary|summar|wording|typo|naming|duplicate|todo|comment|log|boilerplate|test skeleton'
    if ($TaskText -match $highRisk) {
        Write-Output 'CODEX_REQUIRED'
    } elseif ($TaskText -match $localSafe) {
        Write-Output 'LOCAL_FIRST_THEN_CODEX_VERIFY'
    } else {
        Write-Output 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS'
    }
}

function Invoke-Local {
    param([string]$Path,[string]$TaskText,[string[]]$SelectedFiles,[string]$LocalModel)
    if (-not $TaskText) { throw 'Task is required for local.' }
    $root = Resolve-RepositoryRoot $Path
    $runner = Join-Path $root 'scripts\ai-local-task.ps1'
    if (-not (Test-Path $runner)) { throw 'Project is not adopted or local runner is missing.' }
    & $runner -Task $TaskText -Files $SelectedFiles -Model $LocalModel
}

function Invoke-Review {
    param([string]$Path)
    $root = Resolve-RepositoryRoot $Path
    Push-Location $root
    try {
        $changed = @(& git diff --name-only; & git diff --cached --name-only) | Where-Object { $_ } | Sort-Object -Unique
        if (-not $changed) { Write-Host 'No changed files to review.'; return }
        $safe = $changed | Where-Object { $_ -notmatch '(?i)\.env|secret|credential|token|\.pem$|\.p12$|\.pfx$' } | Select-Object -First 12
        & (Join-Path $root 'scripts\ai-local-task.ps1') -Task 'Perform a read-only first-pass review. Report likely bugs, duplication, unclear names, TODOs, and missing tests. Do not approve security, architecture, migrations, auth, production, or release changes.' -Files $safe -Model $Model
    } finally { Pop-Location }
}

switch ($Command) {
    'doctor' { Invoke-Doctor }
    'adopt'  { Invoke-Adopt $ProjectPath }
    'update' { Invoke-Update $ProjectPath }
    'route'  { Invoke-Route $Task }
    'local'  { Invoke-Local $ProjectPath $Task $Files $Model }
    'review' { Invoke-Review $ProjectPath }
}
