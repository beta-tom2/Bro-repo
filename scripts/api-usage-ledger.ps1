[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('record','summary')]
    [string]$Action,
    [string]$ProjectPath='.',
    [string]$Provider='',
    [string]$Model='',
    [int64]$InputTokens=0,
    [int64]$OutputTokens=0,
    [int64]$ReasoningTokens=0,
    [int64]$CachedTokens=0,
    [double]$VendorMultiplier=1.0,
    [int]$RequestCount=1,
    [double]$DurationSeconds=0,
    [ValidateSet('completed','failed','blocked','unknown')]
    [string]$Outcome='unknown',
    [string]$Task='',
    [string]$Notes=''
)

$ErrorActionPreference='Stop'

function Resolve-RepoRoot([string]$Path) {
    $resolved=(Resolve-Path -LiteralPath $Path).Path
    Push-Location $resolved
    try {
        $root=(& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $root) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($root)
    } finally { Pop-Location }
}

$root=Resolve-RepoRoot $ProjectPath
$dir=Join-Path $root '.ai\analytics'
$path=Join-Path $dir 'api-usage-ledger.jsonl'

if ($Action -eq 'record') {
    if (-not $Provider) { throw 'Provider is required for record.' }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $rawTokens=$InputTokens+$OutputTokens+$ReasoningTokens
    $vendorUnits=[math]::Round(($rawTokens*$VendorMultiplier),2)
    $branch=(& git -C $root branch --show-current | Out-String).Trim()
    $head=(& git -C $root rev-parse HEAD | Out-String).Trim()
    $entry=[pscustomobject]@{
        timestamp=(Get-Date -Format o)
        project=(Split-Path $root -Leaf)
        branch=$branch
        head=$head
        provider=$Provider
        model=$Model
        requests=$RequestCount
        input_tokens=$InputTokens
        output_tokens=$OutputTokens
        reasoning_tokens=$ReasoningTokens
        cached_tokens=$CachedTokens
        raw_tokens=$rawTokens
        vendor_multiplier=$VendorMultiplier
        vendor_units=$vendorUnits
        duration_seconds=$DurationSeconds
        outcome=$Outcome
        task=$Task
        notes=$Notes
    }
    $line=ConvertTo-Json -InputObject $entry -Compress -Depth 4
    [IO.File]::AppendAllText($path,($line+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    Write-Host "Recorded API usage: $path"
    return
}

if (-not (Test-Path -LiteralPath $path)) {
    Write-Host 'No API usage recorded for this project.'
    return
}
$rows=@()
foreach ($line in Get-Content -LiteralPath $path) {
    if (-not $line.Trim()) { continue }
    try { $rows += ($line | ConvertFrom-Json) } catch { }
}
if (@($rows).Count -eq 0) {
    Write-Host 'API usage ledger exists but contains no readable records.'
    return
}
$groups=$rows | Group-Object provider,model
$summaryRows=@()
foreach ($group in $groups) {
    $items=@($group.Group)
    $summaryRows += [pscustomobject]@{
        provider=$items[0].provider
        model=$items[0].model
        requests=($items | Measure-Object requests -Sum).Sum
        input_tokens=($items | Measure-Object input_tokens -Sum).Sum
        output_tokens=($items | Measure-Object output_tokens -Sum).Sum
        reasoning_tokens=($items | Measure-Object reasoning_tokens -Sum).Sum
        cached_tokens=($items | Measure-Object cached_tokens -Sum).Sum
        raw_tokens=($items | Measure-Object raw_tokens -Sum).Sum
        vendor_units=($items | Measure-Object vendor_units -Sum).Sum
        completed=@($items | Where-Object { $_.outcome -eq 'completed' }).Count
        failed=@($items | Where-Object { $_.outcome -eq 'failed' }).Count
        blocked=@($items | Where-Object { $_.outcome -eq 'blocked' }).Count
    }
}
$summaryRows | Format-Table -AutoSize
