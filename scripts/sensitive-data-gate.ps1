[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectPath,
    [string]$Task='',
    [string[]]$Files=@()
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
$findings=New-Object Collections.Generic.List[object]

function Add-Finding([string]$Kind,[string]$Location,[string]$Detail) {
    $findings.Add([pscustomobject]@{ kind=$Kind; location=$Location; detail=$Detail })
}

$blockedNames='(?i)(^|[\\/])(\.env($|\.)|.*\.(pem|p12|pfx|key)$|credentials?\.(json|ya?ml|toml)$|secrets?\.(json|ya?ml|toml)$)'
$secretPattern='(?i)(api[_-]?key|secret|password|passwd|authorization\s*:\s*bearer|private[_-]?key|client[_-]?secret)\s*[:=]\s*["'']?[^\s"'']{8,}'
$jwtPattern='eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
$connPattern='(?i)(postgres(ql)?|mysql|mongodb(\+srv)?|redis):\/\/[^\s]+'

if ($Task) {
    if ($Task -match $secretPattern) { Add-Finding 'secret-like-text' 'task' 'Credential-like assignment detected.' }
    if ($Task -match $jwtPattern) { Add-Finding 'jwt-like-text' 'task' 'JWT-like token detected.' }
    if ($Task -match $connPattern) { Add-Finding 'connection-string' 'task' 'Database/service connection string detected.' }
}

foreach ($relative in @($Files | Where-Object { $_ })) {
    $full=Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Add-Finding 'missing-file' $relative 'Requested packet file does not exist.'
        continue
    }
    if ($relative -match $blockedNames) {
        Add-Finding 'protected-file-type' $relative 'Secret/config file type is not allowed in external packets.'
        continue
    }
    $item=Get-Item -LiteralPath $full
    if ($item.Length -gt 1000000) {
        Add-Finding 'oversized-file' $relative 'File exceeds 1 MB packet safety limit; narrow the selection.'
        continue
    }
    $text=Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
    if ($null -eq $text) { continue }
    if ($text -match $secretPattern) { Add-Finding 'secret-like-text' $relative 'Credential-like assignment detected.' }
    if ($text -match $jwtPattern) { Add-Finding 'jwt-like-text' $relative 'JWT-like token detected.' }
    if ($text -match $connPattern) { Add-Finding 'connection-string' $relative 'Database/service connection string detected.' }
}

$result=[ordered]@{
    safeForExternal = ($findings.Count -eq 0)
    findingCount = $findings.Count
    findings = @($findings)
    policy = 'Block external transmission when any finding exists; user must sanitize or narrow the packet.'
}
$result | ConvertTo-Json -Depth 6
if ($findings.Count -gt 0) { exit 2 }
