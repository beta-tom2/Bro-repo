[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [int]$LargeFileLines = 700,
    [int]$MaxFindings = 200
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
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path,$Content,$encoding)
}

$root = Resolve-RepoRoot $ProjectPath
Push-Location $root
try {
    $excluded = '(?i)[\\/](node_modules|dist|build|coverage|\.git|\.ai|\.next|\.expo|ios|android|vendor)[\\/]'
    $sourceExtensions = @('.ts','.tsx','.js','.jsx','.mjs','.cjs','.py','.ps1','.rs','.go','.java','.kt','.kts')
    $sourceFiles = @(Get-ChildItem $root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $sourceExtensions -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch $excluded -and $_.Length -lt 1000000 })

    $large = New-Object Collections.Generic.List[object]
    $todo = New-Object Collections.Generic.List[object]
    $todoCount = 0
    foreach ($file in $sourceFiles) {
        $lineCount = 0
        try {
            $content = @(Get-Content -LiteralPath $file.FullName -ErrorAction Stop)
            $lineCount = $content.Count
            if ($lineCount -ge $LargeFileLines) {
                $large.Add([pscustomobject]@{ File=$file.FullName.Substring($root.Length + 1); Lines=$lineCount })
            }
            for ($i = 0; $i -lt $content.Count; $i++) {
                if ($content[$i] -match '(?i)\b(TODO|FIXME|HACK|XXX)\b') {
                    $todoCount++
                    if ($todo.Count -lt $MaxFindings) {
                        $todo.Add([pscustomobject]@{ File=$file.FullName.Substring($root.Length + 1); Line=($i + 1); Text=$content[$i].Trim() })
                    }
                }
            }
        }
        catch { }
    }

    $conflicts = @(& git grep -n -I -e '^<<<<<<< ' -e '^=======$' -e '^>>>>>>> ' 2>$null)
    $statusLines = @(& git status --porcelain=v1 2>$null | Where-Object { $_ })
    $status = ($statusLines | Out-String).TrimEnd()
    $recent = (& git log -n 10 --pretty=format:'%h %ad %s' --date=short | Out-String).TrimEnd()
    $rankedLarge = @($large | Sort-Object Lines -Descending | Select-Object -First 80)

    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        repository = $root
        branch = (& git branch --show-current 2>$null | Out-String).Trim()
        head = (& git rev-parse HEAD 2>$null | Out-String).Trim()
        metrics = [ordered]@{
            sourceFiles = $sourceFiles.Count
            conflictMarkers = $conflicts.Count
            largeSourceFiles = $large.Count
            todoMarkers = $todoCount
            changedFiles = $statusLines.Count
        }
        changedFiles = @($statusLines | ForEach-Object { [string]$_ })
        conflicts = @($conflicts | ForEach-Object { [string]$_ })
        largeFiles = @($rankedLarge)
        todoFindings = @($todo)
        safety = 'Read-only deterministic audit; findings are advisory.'
    }
    Write-Utf8NoBom (Join-Path $root '.ai\analytics\night-audit.generated.json') ($payload | ConvertTo-Json -Depth 10)

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# ADOS read-only night audit')
    $lines.Add('')
    $lines.Add("Generated: $(Get-Date -Format o)")
    $lines.Add("Repository: $root")
    $lines.Add('')
    $lines.Add('## Working tree')
    $lines.Add('```text')
    $lines.Add($(if ($status) { $status } else { 'clean' }))
    $lines.Add('```')
    $lines.Add('')
    $lines.Add('## Conflict markers')
    if ($conflicts.Count) { foreach ($item in $conflicts) { $lines.Add("- ``$item``") } } else { $lines.Add('- none') }
    $lines.Add('')
    $lines.Add("## Large source files (at least $LargeFileLines lines)")
    if ($rankedLarge.Count) { foreach ($item in $rankedLarge) { $lines.Add("- ``$($item.File)``: $($item.Lines) lines") } } else { $lines.Add('- none') }
    if ($large.Count -gt $rankedLarge.Count) { $lines.Add("- ... $($large.Count - $rankedLarge.Count) additional large files omitted") }
    $lines.Add('')
    $lines.Add('## TODO and FIXME markers')
    if ($todo.Count) { foreach ($item in $todo) { $lines.Add("- ``$($item.File):$($item.Line)`` $($item.Text)") } } else { $lines.Add('- none') }
    if ($todoCount -gt $todo.Count) { $lines.Add("- ... $($todoCount - $todo.Count) additional findings omitted") }
    $lines.Add('')
    $lines.Add('## Recent commits')
    $lines.Add('```text')
    $lines.Add($recent)
    $lines.Add('```')
    $lines.Add('')
    $lines.Add('## Safety')
    $lines.Add('- This audit made no product-code changes.')
    $lines.Add('- Findings are candidates for review, not confirmed defects.')
    $lines.Add('- Security, architecture, migrations, auth, production, and release work still require Codex-level review.')

    $output = Join-Path $root '.ai\analytics\night-audit.generated.md'
    Write-Utf8NoBom $output ($lines -join "`r`n")
    Write-Host "Night audit written to $output"
}
finally { Pop-Location }
