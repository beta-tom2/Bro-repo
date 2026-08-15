[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectPath,
    [Parameter(Mandatory=$true)]
    [string]$Task,
    [string[]]$Files=@(),
    [string]$OutputPath=''
)

$ErrorActionPreference='Stop'
$DevCoreRoot=Split-Path -Parent $PSScriptRoot
$Gate=Join-Path $PSScriptRoot 'sensitive-data-gate.ps1'
if (-not (Test-Path -LiteralPath $Gate)) { throw "Sensitive data gate not found: $Gate" }

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
if (-not $OutputPath) {
    $dir=Join-Path $root '.ai\external-api'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $OutputPath=Join-Path $dir 'task-packet.generated.md'
}

$gateOutput=& $Gate -ProjectPath $root -Task $Task -Files $Files 2>&1
$gateCode=$LASTEXITCODE
if ($gateCode -ne 0) {
    Write-Host $gateOutput
    throw 'External task packet blocked by sensitive-data gate. Sanitize or narrow the packet before retrying.'
}

$branch=(& git -C $root branch --show-current | Out-String).Trim()
$head=(& git -C $root rev-parse HEAD | Out-String).Trim()
$lines=New-Object Collections.Generic.List[string]
$lines.Add('# External API task packet')
$lines.Add('')
$lines.Add('> LOCAL PREVIEW ONLY — external transmission is disabled until a provider is configured and the user explicitly requests API execution.')
$lines.Add('')
$lines.Add("Project: $(Split-Path $root -Leaf)")
$lines.Add("Branch: $branch")
$lines.Add("HEAD: $head")
$lines.Add('Route: EXTERNAL_API (explicit user request required)')
$lines.Add('')
$lines.Add('## Task')
$lines.Add($Task)
$lines.Add('')
$lines.Add('## Selected files')
if (@($Files).Count -eq 0) { $lines.Add('- none') }
foreach ($relative in @($Files | Where-Object { $_ })) {
    $full=Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $lines.Add('')
    $lines.Add("### $relative")
    $lines.Add('```text')
    $lines.Add((Get-Content -LiteralPath $full -Raw))
    $lines.Add('```')
}
$lines.Add('')
$lines.Add('## External boundary')
$lines.Add('- Do not infer or request unrelated repository context.')
$lines.Add('- Do not request secrets, credentials, production access, GitHub/Supabase shell access, or external tools.')
$lines.Add('- Return analysis/text only unless the task explicitly requests a patch or code output.')
$lines.Add('- The trusted Codex environment remains responsible for applying and verifying any returned change.')

$parent=Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
[IO.File]::WriteAllText($OutputPath,($lines -join [Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
Write-Host "External task packet prepared locally: $OutputPath"
Write-Host 'Transmission status: DISABLED / provider NOT_CONFIGURED'
