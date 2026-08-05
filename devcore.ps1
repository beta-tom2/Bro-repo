[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('doctor','adopt','update','route','local','review','packet','register','projects')]
    [string]$Command,

    [string]$ProjectPath = '.',
    [string]$Task = '',
    [string[]]$Files = @(),
    [string]$Model = 'qwen2.5-coder:7b',
    [int]$ContextBudgetBytes = 160000
)

$ErrorActionPreference = 'Stop'
$DevCoreRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RegistryPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.albert-devcore\projects.json'

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

function Ensure-Directory {
    param([string]$Path)
    if ($Path) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    Ensure-Directory (Split-Path -Parent $Path)
    [IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))
}

function Get-RelativePathCompat {
    param([string]$Root,[string]$FullPath)
    $rootUri = New-Object System.Uri(($Root.TrimEnd('\') + '\'))
    $fileUri = New-Object System.Uri($FullPath)
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fileUri).ToString()).Replace('/','\')
}

function Invoke-Doctor {
    $checks = @(
        @{ Name='git'; Required=$true; Present=(Test-CommandAvailable 'git') },
        @{ Name='rg'; Required=$true; Present=(Test-CommandAvailable 'rg') },
        @{ Name='ollama'; Required=$false; Present=(Test-CommandAvailable 'ollama') },
        @{ Name='node'; Required=$false; Present=(Test-CommandAvailable 'node') },
        @{ Name='npm'; Required=$false; Present=(Test-CommandAvailable 'npm') }
    )
    $failed = $false
    foreach ($check in $checks) {
        $status = if ($check.Present) { 'PASS' } elseif ($check.Required) { $failed=$true; 'FAIL' } else { 'OPTIONAL-MISSING' }
        Write-Host ('{0,-18} {1}' -f $check.Name, $status)
    }
    Write-Host ('{0,-18} {1}' -f 'registry', $(if (Test-Path $RegistryPath) { 'PASS' } else { 'EMPTY' }))
    if (Test-CommandAvailable 'ollama') {
        Write-Host "`nLocal models:"
        & ollama list
    }
    if ($failed) { throw 'Required DevCore tools are missing.' }
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

function Add-IgnoreRules {
    param([string]$Root)
    $ignore = Join-Path $Root '.gitignore'
    $required = @(
        '.ai/context/session-context.md',
        '.ai/context/repo-map.generated.md',
        '.ai/context/import-map.generated.md',
        '.ai/context/test-plan.generated.md',
        '.ai/context/prompt-packet.generated.md',
        '.ai/local-output/',
        '.ai/cache/',
        '*.local-ai.log'
    )
    $existing = if (Test-Path $ignore) { @(Get-Content $ignore) } else { @() }
    foreach ($line in $required) {
        if ($existing -notcontains $line) { Add-Content -Path $ignore -Value $line -Encoding UTF8 }
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
    Add-IgnoreRules $root
    Invoke-Register $root
    Invoke-Update $root
}

function Get-ChangedFiles {
    param([string]$Root)
    Push-Location $Root
    try {
        $items = @()
        $items += (& git diff --name-only)
        $items += (& git diff --cached --name-only)
        $items += (& git ls-files --others --exclude-standard)
        return @($items | Where-Object { $_ } | Sort-Object -Unique)
    } finally { Pop-Location }
}

function Get-SourceFiles {
    param([string]$Root,[int]$Limit=300)
    $extensions = @('.ts','.tsx','.js','.jsx','.mjs','.cjs','.py','.rs','.go','.java','.kt','.kts')
    $excluded = '(?i)[\\/](node_modules|dist|build|coverage|\.git|\.ai|\.next|\.expo|ios|android|vendor)[\\/]'
    return @(Get-ChildItem $Root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch $excluded -and $_.Length -lt 300000 } |
        Sort-Object FullName | Select-Object -First $Limit)
}

function New-ImportMap {
    param([string]$Root)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Generated import map')
    $lines.Add('')
    $lines.Add("Generated: $(Get-Date -Format o)")
    $lines.Add('')
    $lines.Add('This is a lightweight lexical map, not a compiler-resolved dependency graph.')
    $lines.Add('')

    $files = Get-SourceFiles $Root 300
    foreach ($file in $files) {
        $relative = Get-RelativePathCompat $Root $file.FullName
        $matches = New-Object Collections.Generic.List[string]
        foreach ($line in (Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*import\s+.*?from\s+["'']([^"'']+)["'']' -or $line -match '^\s*import\s+["'']([^"'']+)["'']' -or $line -match 'require\(["'']([^"'']+)["'']\)') {
                if ($matches -notcontains $Matches[1]) { $matches.Add($Matches[1]) }
            } elseif ($file.Extension -eq '.py' -and ($line -match '^\s*from\s+([A-Za-z0-9_\.]+)\s+import' -or $line -match '^\s*import\s+([A-Za-z0-9_\.]+)')) {
                if ($matches -notcontains $Matches[1]) { $matches.Add($Matches[1]) }
            }
        }
        if ($matches.Count -gt 0) {
            $lines.Add("## ``$relative``")
            foreach ($item in ($matches | Select-Object -First 20)) { $lines.Add("- ``$item``") }
            $lines.Add('')
        }
    }
    Write-Utf8NoBom (Join-Path $Root '.ai\context\import-map.generated.md') ($lines -join "`r`n")
}

function Get-TestRecommendations {
    param([string]$Root,[string[]]$Changed)
    $commands = New-Object Collections.Generic.List[string]
    $reasons = New-Object Collections.Generic.List[string]
    $packagePath = Join-Path $Root 'package.json'
    $scripts = @{}
    if (Test-Path $packagePath) {
        try {
            $package = Get-Content $packagePath -Raw | ConvertFrom-Json
            if ($package.scripts) {
                foreach ($property in $package.scripts.PSObject.Properties) { $scripts[$property.Name] = [string]$property.Value }
            }
        } catch { }
    }

    function Add-Test([string]$Command,[string]$Reason) {
        if ($Command -and $commands -notcontains $Command) { $commands.Add($Command); $reasons.Add($Reason) }
    }

    if ($scripts.ContainsKey('typecheck')) { Add-Test 'npm run typecheck' 'TypeScript validation is available.' }
    elseif ($scripts.ContainsKey('check:typecheck')) { Add-Test 'npm run check:typecheck' 'TypeScript validation is available.' }

    if ($Changed -match '\.(ts|tsx|js|jsx|mjs|cjs)$') {
        if ($scripts.ContainsKey('test:ci')) { Add-Test 'npm run test:ci' 'Source code changed.' }
        elseif ($scripts.ContainsKey('test')) { Add-Test 'npm test' 'Source code changed.' }
    }
    if ($Changed -match '(?i)(screen|component|ui|style|css|scss|tsx)') {
        if ($scripts.ContainsKey('check:ui-copy')) { Add-Test 'npm run check:ui-copy' 'User-facing UI may have changed.' }
        if ($scripts.ContainsKey('check:accessibility')) { Add-Test 'npm run check:accessibility' 'UI accessibility may be affected.' }
    }
    if ($Changed -match '(?i)(supabase|migration|\.sql$|rls)') {
        if ($scripts.ContainsKey('check:supabase-security')) { Add-Test 'npm run check:supabase-security' 'Supabase or SQL boundary changed.' }
        if ($scripts.ContainsKey('check:sql')) { Add-Test 'npm run check:sql' 'SQL files changed.' }
    }
    if ($scripts.ContainsKey('check:conflicts')) { Add-Test 'npm run check:conflicts' 'Conflict marker check is cheap and deterministic.' }
    if ($scripts.ContainsKey('check:secrets')) { Add-Test 'npm run check:secrets' 'Secret scanning is cheap and deterministic.' }
    Add-Test 'git diff --check' 'Whitespace and patch integrity check.'

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Generated focused test plan')
    $lines.Add('')
    $lines.Add("Generated: $(Get-Date -Format o)")
    $lines.Add('')
    if ($commands.Count -eq 0) { $lines.Add('- No project-specific checks detected.') }
    else {
        for ($i=0; $i -lt $commands.Count; $i++) { $lines.Add("- ``$($commands[$i])`` — $($reasons[$i])") }
    }
    Write-Utf8NoBom (Join-Path $Root '.ai\context\test-plan.generated.md') ($lines -join "`r`n")
    return @($commands)
}

function Invoke-Update {
    param([string]$Path)
    $root = Resolve-RepositoryRoot $Path
    Push-Location $root
    try {
        Ensure-Directory (Join-Path $root '.ai\context')
        Add-IgnoreRules $root
        $branch = (& git branch --show-current | Out-String).Trim()
        $head = (& git rev-parse HEAD | Out-String).Trim()
        $status = (& git status --short | Out-String).TrimEnd()
        $diff = (& git diff --stat | Out-String).TrimEnd()
        $recent = (& git log -n 12 --pretty=format:'%h %ad %s' --date=short | Out-String).TrimEnd()
        $changed = Get-ChangedFiles $root

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
        $map.Add('')
        $map.Add('## Current changed files')
        if ($changed.Count -eq 0) { $map.Add('- none') } else { foreach ($item in $changed) { $map.Add("- ``$item``") } }
        Write-Utf8NoBom (Join-Path $root '.ai\context\repo-map.generated.md') ($map -join "`r`n")

        New-ImportMap $root
        $null = Get-TestRecommendations $root $changed

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
6. .ai/context/import-map.generated.md
7. .ai/context/test-plan.generated.md
8. changed files and focused tests
"@
        Write-Utf8NoBom (Join-Path $root '.ai\context\session-context.md') $ctx
        Write-Host "Updated DevCore context for $root"
    } finally { Pop-Location }
}

function Invoke-Route {
    param([string]$TaskText)
    if (-not $TaskText) { throw 'Task is required for route.' }
    $critical = '(?i)auth|security|rls|sql|migration|production|release|payment|broker|trading|financial|secret|credential|deploy|architecture|dependency|native|permission|encryption'
    $localSafe = '(?i)readme|documentation|summary|summar|wording|typo|naming|duplicate|todo|comment|log|boilerplate|test skeleton|changelog'
    if ($TaskText -match $critical) { 'CODEX_REQUIRED' }
    elseif ($TaskText -match $localSafe) { 'LOCAL_FIRST_THEN_CODEX_VERIFY' }
    else { 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS' }
}

function Get-TaskTerms {
    param([string]$TaskText)
    $stop = @('the','and','for','with','from','this','that','как','для','или','это','надо','нужно','исправить','добавить','сделать','проверить')
    return @($TaskText.ToLowerInvariant() -split '[^\p{L}\p{Nd}_-]+' | Where-Object { $_.Length -ge 4 -and $stop -notcontains $_ } | Sort-Object -Unique | Select-Object -First 10)
}

function Invoke-Packet {
    param([string]$Path,[string]$TaskText,[int]$Budget)
    if (-not $TaskText) { throw 'Task is required for packet.' }
    $root = Resolve-RepositoryRoot $Path
    Invoke-Update $root
    $route = Invoke-Route $TaskText
    $changed = Get-ChangedFiles $root
    $terms = Get-TaskTerms $TaskText
    $candidates = New-Object Collections.Generic.List[string]

    Push-Location $root
    try {
        foreach ($term in $terms) {
            $hits = & rg -l --hidden --glob '!node_modules/**' --glob '!.git/**' --glob '!.ai/**' --glob '!dist/**' --glob '!build/**' --glob '!coverage/**' --glob '!ios/**' --glob '!android/**' --fixed-strings $term . 2>$null
            foreach ($hit in $hits) {
                $clean = $hit.TrimStart('.','\','/')
                if ($clean -and $candidates -notcontains $clean) { $candidates.Add($clean) }
                if ($candidates.Count -ge 30) { break }
            }
            if ($candidates.Count -ge 30) { break }
        }
    } finally { Pop-Location }

    $selected = New-Object Collections.Generic.List[string]
    $used = 0
    $priority = @('AGENTS.md','README.md','.ai\context\current-state.md','.ai\context\decisions.md','.ai\context\repo-map.generated.md','.ai\context\import-map.generated.md','.ai\context\test-plan.generated.md') + $changed + $candidates
    foreach ($item in ($priority | Where-Object { $_ } | Select-Object -Unique)) {
        $full = Join-Path $root $item
        if (Test-Path $full -PathType Leaf) {
            $length = (Get-Item $full).Length
            if ($length -le 80000 -and ($used + $length) -le $Budget) { $selected.Add($item); $used += $length }
        }
    }

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Generated prompt packet')
    $lines.Add('')
    $lines.Add("Generated: $(Get-Date -Format o)")
    $lines.Add("Route: $route")
    $lines.Add("Context budget: $Budget bytes")
    $lines.Add("Selected bytes: $used")
    $lines.Add('')
    $lines.Add('## Task')
    $lines.Add('')
    $lines.Add($TaskText)
    $lines.Add('')
    $lines.Add('## Selected files')
    if ($selected.Count -eq 0) { $lines.Add('- none') } else { foreach ($item in $selected) { $lines.Add("- ``$item``") } }
    $lines.Add('')
    $lines.Add('## Execution contract')
    $lines.Add('- Read selected files first; expand only when references or tests require it.')
    $lines.Add('- Use deterministic tools before broad model reasoning.')
    $lines.Add('- Run focused checks from test-plan.generated.md.')
    $lines.Add('- Treat generated context as a navigation aid, not source of truth.')
    $packetPath = Join-Path $root '.ai\context\prompt-packet.generated.md'
    Write-Utf8NoBom $packetPath ($lines -join "`r`n")
    Write-Host "Prompt packet written to $packetPath"
    Write-Output $route
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
        $changed = Get-ChangedFiles $root
        if (-not $changed) { Write-Host 'No changed files to review.'; return }
        $safe = $changed | Where-Object { $_ -notmatch '(?i)\.env|secret|credential|token|\.pem$|\.p12$|\.pfx$' } | Select-Object -First 12
        & (Join-Path $root 'scripts\ai-local-task.ps1') -Task 'Perform a read-only first-pass review. Report likely bugs, duplication, unclear names, TODOs, and missing tests. Do not approve security, architecture, migrations, auth, production, or release changes.' -Files $safe -Model $Model
    } finally { Pop-Location }
}

function Read-Registry {
    if (-not (Test-Path $RegistryPath)) { return @() }
    try { return @((Get-Content $RegistryPath -Raw | ConvertFrom-Json)) } catch { return @() }
}

function Write-Registry {
    param([object[]]$Items)
    Ensure-Directory (Split-Path -Parent $RegistryPath)
    Write-Utf8NoBom $RegistryPath (($Items | ConvertTo-Json -Depth 5))
}

function Invoke-Register {
    param([string]$Path)
    $root = Resolve-RepositoryRoot $Path
    $items = @(Read-Registry)
    $name = Split-Path $root -Leaf
    $remote = ''
    Push-Location $root
    try { $remote = (& git remote get-url origin 2>$null | Out-String).Trim() } finally { Pop-Location }
    $filtered = @($items | Where-Object { $_.path -ne $root })
    $entry = [PSCustomObject]@{ name=$name; path=$root; remote=$remote; registered_at=(Get-Date -Format o) }
    Write-Registry @($filtered + $entry)
    Write-Host "Registered: $name -> $root"
}

function Invoke-Projects {
    $items = @(Read-Registry)
    if ($items.Count -eq 0) { Write-Host 'No registered projects.'; return }
    $items | Sort-Object name | Format-Table name,path,remote -AutoSize
}

switch ($Command) {
    'doctor'   { Invoke-Doctor }
    'adopt'    { Invoke-Adopt $ProjectPath }
    'update'   { Invoke-Update $ProjectPath }
    'route'    { Invoke-Route $Task }
    'local'    { Invoke-Local $ProjectPath $Task $Files $Model }
    'review'   { Invoke-Review $ProjectPath }
    'packet'   { Invoke-Packet $ProjectPath $Task $ContextBudgetBytes }
    'register' { Invoke-Register $ProjectPath }
    'projects' { Invoke-Projects }
}
