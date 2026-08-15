[CmdletBinding()]
param(
    [switch]$AllRegisteredProjects,
    [string[]]$ProjectPath = @(),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$DevCoreRoot = Split-Path -Parent $PSScriptRoot
$TemplatePath = Join-Path $DevCoreRoot 'template\AGENTS.md'
$RegistryBase = $env:USERPROFILE
if (-not $RegistryBase) { $RegistryBase = $HOME }
if (-not $RegistryBase) { $RegistryBase = $DevCoreRoot }
$RegistryPath = Join-Path $RegistryBase '.albert-devcore\projects.json'
$StartMarker = '<!-- ALBERT-CRITICAL-ENGINEERING-POLICY:START -->'
$EndMarker = '<!-- ALBERT-CRITICAL-ENGINEERING-POLICY:END -->'

function Read-Utf8([string]$Path) {
    return [IO.File]::ReadAllText($Path)
}

function Write-Utf8NoBom([string]$Path,[string]$Content) {
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

function Get-CanonicalPolicy {
    $template = Read-Utf8 $TemplatePath
    $start = $template.IndexOf('## Critical engineering policy')
    if ($start -lt 0) { throw 'Critical engineering policy section not found in template/AGENTS.md' }
    $next = $template.IndexOf("`n## ", $start + 4)
    if ($next -lt 0) { $section = $template.Substring($start).Trim() }
    else { $section = $template.Substring($start, $next - $start).Trim() }
    return "$StartMarker`r`n$section`r`n$EndMarker"
}

function Normalize-RegistryEntries($Value) {
    $result = New-Object Collections.Generic.List[object]
    function Walk($Node) {
        if ($null -eq $Node) { return }
        if ($Node -is [System.Array]) { foreach ($item in $Node) { Walk $item }; return }
        if ($Node.PSObject -and $Node.PSObject.Properties['path']) {
            $path = [string]$Node.path
            if ($path) {
                $name = if ($Node.PSObject.Properties['name']) { [string]$Node.name } else { Split-Path $path -Leaf }
                $registered = if ($Node.PSObject.Properties['registered']) { [string]$Node.registered } else { '' }
                $result.Add([pscustomobject]@{ name=$name; path=$path; registered=$registered })
            }
            return
        }
        if ($Node.PSObject) {
            foreach ($p in $Node.PSObject.Properties) { Walk $p.Value }
        }
    }
    Walk $Value
    return @($result | Group-Object path | ForEach-Object { $_.Group[0] })
}

function Get-Targets {
    $targets = New-Object Collections.Generic.List[string]
    foreach ($p in $ProjectPath) {
        if (-not $p) { continue }
        $resolved = (Resolve-Path -LiteralPath $p).Path
        if ($targets -notcontains $resolved) { $targets.Add($resolved) }
    }
    if ($AllRegisteredProjects) {
        if (-not (Test-Path -LiteralPath $RegistryPath)) { throw "Registry not found: $RegistryPath" }
        $raw = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
        foreach ($entry in (Normalize-RegistryEntries $raw)) {
            if (-not (Test-Path -LiteralPath $entry.path)) {
                Write-Warning "Skipping missing registered project: $($entry.path)"
                continue
            }
            $resolved = (Resolve-Path -LiteralPath $entry.path).Path
            if ($targets -notcontains $resolved) { $targets.Add($resolved) }
        }
    }
    return @($targets)
}

function Sync-Policy([string]$Root,[string]$Policy) {
    $agents = Join-Path $Root 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $agents)) {
        $content = "# Project agent rules`r`n`r`n$Policy`r`n"
        if ($DryRun) { Write-Host "[DRY RUN] create $agents" }
        else { Write-Utf8NoBom $agents $content; Write-Host "Created: $agents" }
        return
    }
    $text = Read-Utf8 $agents
    $s = $text.IndexOf($StartMarker)
    $e = $text.IndexOf($EndMarker)
    if ($s -ge 0 -and $e -gt $s) {
        $e += $EndMarker.Length
        $updated = $text.Substring(0,$s).TrimEnd() + "`r`n`r`n" + $Policy + "`r`n" + $text.Substring($e).TrimStart()
        if ($DryRun) { Write-Host "[DRY RUN] update managed policy in $agents" }
        else { Write-Utf8NoBom $agents $updated; Write-Host "Updated managed policy: $agents" }
        return
    }
    if ($text -match '(?m)^## Critical engineering policy\s*$') {
        Write-Warning "Unmanaged Critical engineering policy already exists; preserving project copy: $agents"
        return
    }
    $updated = $text.TrimEnd() + "`r`n`r`n" + $Policy + "`r`n"
    if ($DryRun) { Write-Host "[DRY RUN] append policy to $agents" }
    else { Write-Utf8NoBom $agents $updated; Write-Host "Appended managed policy: $agents" }
}

$policy = Get-CanonicalPolicy
$targets = Get-Targets
if ($targets.Count -eq 0) { throw 'No project targets selected. Use -AllRegisteredProjects or -ProjectPath.' }

foreach ($root in $targets) {
    Push-Location $root
    try {
        $repo = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $repo) { Write-Warning "Skipping non-Git project: $root"; continue }
        $status = (& git status --short | Out-String).TrimEnd()
        if ($status) { Write-Warning "Project has existing changes; policy sync will only touch AGENTS.md: $repo" }
        Sync-Policy -Root $repo -Policy $policy
    }
    finally { Pop-Location }
}

Write-Host 'Albert Critical Engineering Policy sync completed.'
