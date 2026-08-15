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

function Read-Utf8([string]$Path) { return [IO.File]::ReadAllText($Path) }
function Write-Utf8NoBom([string]$Path,[string]$Content) { [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false))) }

function Get-CanonicalSection([string]$Heading,[string]$StartMarker,[string]$EndMarker) {
    $template = Read-Utf8 $TemplatePath
    $start = $template.IndexOf("## $Heading")
    if ($start -lt 0) { throw "$Heading section not found in template/AGENTS.md" }
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
        if ($Node.PSObject) { foreach ($p in $Node.PSObject.Properties) { Walk $p.Value } }
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

function Sync-ManagedSection([string]$Agents,[string]$Heading,[string]$StartMarker,[string]$EndMarker,[string]$Policy) {
    if (-not (Test-Path -LiteralPath $Agents)) {
        $content = "# Project agent rules`r`n`r`n$Policy`r`n"
        if ($DryRun) { Write-Host "[DRY RUN] create $Agents with $Heading" }
        else { Write-Utf8NoBom $Agents $content; Write-Host "Created: $Agents ($Heading)" }
        return
    }
    $text = Read-Utf8 $Agents
    $s = $text.IndexOf($StartMarker)
    $e = $text.IndexOf($EndMarker)
    if ($s -ge 0 -and $e -gt $s) {
        $e += $EndMarker.Length
        $updated = $text.Substring(0,$s).TrimEnd() + "`r`n`r`n" + $Policy + "`r`n" + $text.Substring($e).TrimStart()
        if ($DryRun) { Write-Host "[DRY RUN] update managed $Heading in $Agents" }
        else { Write-Utf8NoBom $Agents $updated; Write-Host "Updated managed $Heading: $Agents" }
        return
    }
    $escaped=[regex]::Escape("## $Heading")
    if ($text -match "(?m)^$escaped\s*$") {
        Write-Warning "Unmanaged $Heading already exists; preserving project copy: $Agents"
        return
    }
    $updated = $text.TrimEnd() + "`r`n`r`n" + $Policy + "`r`n"
    if ($DryRun) { Write-Host "[DRY RUN] append $Heading to $Agents" }
    else { Write-Utf8NoBom $Agents $updated; Write-Host "Appended managed $Heading: $Agents" }
}

$criticalStart='<!-- ALBERT-CRITICAL-ENGINEERING-POLICY:START -->'
$criticalEnd='<!-- ALBERT-CRITICAL-ENGINEERING-POLICY:END -->'
$routeStart='<!-- ALBERT-EXECUTION-ROUTING-POLICY:START -->'
$routeEnd='<!-- ALBERT-EXECUTION-ROUTING-POLICY:END -->'
$critical=Get-CanonicalSection 'Critical engineering policy' $criticalStart $criticalEnd
$routing=Get-CanonicalSection 'Execution routing policy' $routeStart $routeEnd

$targets = Get-Targets
if ($targets.Count -eq 0) { throw 'No project targets selected. Use -AllRegisteredProjects or -ProjectPath.' }

foreach ($root in $targets) {
    Push-Location $root
    try {
        $repo = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $repo) { Write-Warning "Skipping non-Git project: $root"; continue }
        $status = (& git status --short | Out-String).TrimEnd()
        if ($status) { Write-Warning "Project has existing changes; policy sync will only touch AGENTS.md: $repo" }
        $agents=Join-Path $repo 'AGENTS.md'
        Sync-ManagedSection $agents 'Critical engineering policy' $criticalStart $criticalEnd $critical
        Sync-ManagedSection $agents 'Execution routing policy' $routeStart $routeEnd $routing
    }
    finally { Pop-Location }
}

Write-Host 'Albert Critical Engineering + MANUAL Execution Routing Policy sync completed.'
