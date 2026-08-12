[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Task,
    [string[]]$Files = @(),
    [string]$Model = 'qwen2.5-coder:7b',
    [int]$MaxFileBytes = 40000,
    [int]$MaxTotalBytes = 120000
)

$ErrorActionPreference = 'Stop'
$blockedPatterns = @('(?i)\.env($|\.)','(?i)secret','(?i)credential','(?i)token','(?i)private[-_]?key','(?i)\.pem$','(?i)\.p12$','(?i)\.pfx$','(?i)wallet','(?i)broker','(?i)production')
$allowedExtensions = @('.md','.txt','.json','.yaml','.yml','.toml','.ts','.tsx','.js','.jsx','.mjs','.cjs','.py','.rs','.go','.java','.kt','.kts','.html','.css','.scss','.sql','.ps1','.sh')

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) { throw 'Ollama is not available in PATH.' }
$repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if (-not $repoRoot) { throw 'Run this script inside a Git repository.' }
$repoRoot = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\','/')
$repoPrefix = $repoRoot + [IO.Path]::DirectorySeparatorChar
Set-Location $repoRoot

function Relative-PathCompat([string]$Root,[string]$FullPath) {
    $rootUri = New-Object Uri(($Root.TrimEnd('\') + '\'))
    $fileUri = New-Object Uri($FullPath)
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fileUri).ToString()).Replace('/','\')
}

$sections = New-Object Collections.Generic.List[string]
$totalBytes = 0
foreach ($file in $Files) {
    $candidate = if ([IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $repoRoot $file }
    $fullPath = [IO.Path]::GetFullPath($candidate)
    if (($fullPath -ne $repoRoot) -and (-not $fullPath.StartsWith($repoPrefix,[StringComparison]::OrdinalIgnoreCase))) { throw "File is outside repository: $file" }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Missing file: $file" }
    $relative = Relative-PathCompat $repoRoot $fullPath
    foreach ($pattern in $blockedPatterns) { if ($relative -match $pattern) { throw "Blocked sensitive file: $relative" } }
    $extension = [IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    if ($allowedExtensions -notcontains $extension) { throw "Unsupported file type: $relative" }
    $info = Get-Item -LiteralPath $fullPath
    if ($info.Length -gt $MaxFileBytes) { throw "File exceeds MaxFileBytes: $relative" }
    if (($totalBytes + $info.Length) -gt $MaxTotalBytes) { throw 'Selected files exceed MaxTotalBytes.' }
    $sections.Add("--- FILE: $relative ---")
    $sections.Add((Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8))
    $totalBytes += $info.Length
}

$rules = @'
You are a local read-only development assistant.
Do not claim to modify files, run tests, access hidden content or verify facts not supplied.
Do not approve architecture, security, authentication, permissions, migrations, finance, production or release changes. State that Codex review is required for those.
Return concise findings with exact file references and clearly labeled uncertainty.
'@
$context = if ($sections.Count) { $sections -join "`n`n" } else { 'No files supplied.' }
$prompt = "$rules`n`nTASK:`n$Task`n`nREAD-ONLY CONTEXT:`n$context"
$outputDir = Join-Path $repoRoot '.ai\local-output'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$outputPath = Join-Path $outputDir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '.md')
$response = $prompt | & ollama run $Model
if ($LASTEXITCODE -ne 0) { throw "Ollama failed with exit code $LASTEXITCODE." }
$report = "# Local AI result`n`nGenerated: $(Get-Date -Format o)`nModel: $Model`nFiles: $($Files.Count)`nInput bytes: $totalBytes`n`n## Task`n`n$Task`n`n## Result`n`n$(($response | Out-String).TrimEnd())`n`n## Trust boundary`n`nUntrusted local-model output. Verify with source files, deterministic tools, tests and Codex."
$encoding = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($outputPath,$report,$encoding)
Write-Host "Local AI result written to $outputPath"
