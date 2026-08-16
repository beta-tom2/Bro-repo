[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectPath,
    [Parameter(Mandatory=$true)]
    [string]$Task,
    [string[]]$Files=@(),
    [string]$Model='',
    [string]$ProviderConfig='',
    [int]$TimeoutSec=600
)

$ErrorActionPreference='Stop'
$ScriptsRoot=$PSScriptRoot
$Router=Join-Path $ScriptsRoot 'manual-execution-router.ps1'
$Gate=Join-Path $ScriptsRoot 'sensitive-data-gate.ps1'
$PacketBuilder=Join-Path $ScriptsRoot 'external-task-packet.ps1'
$Ledger=Join-Path $ScriptsRoot 'api-usage-ledger.ps1'

foreach ($required in @($Router,$Gate,$PacketBuilder,$Ledger)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required DevCore script missing: $required" }
}

function Resolve-RepoRoot([string]$Path) {
    $resolved=(Resolve-Path -LiteralPath $Path).Path
    Push-Location $resolved
    try {
        $root=(& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $root) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($root)
    } finally { Pop-Location }
}

function Get-DefaultProviderConfigPath {
    $home=$env:USERPROFILE
    if (-not $home) { $home=$HOME }
    if (-not $home) { throw 'Cannot determine user home for provider config.' }
    return Join-Path $home '.albert-devcore\external-api-provider.json'
}

function Import-KeyFromCodexEnv([string]$EnvName) {
    $existing=[Environment]::GetEnvironmentVariable($EnvName,'Process')
    if ($existing) { return $existing }
    $home=$env:USERPROFILE
    if (-not $home) { $home=$HOME }
    if (-not $home) { return $null }
    $dotenv=Join-Path $home '.codex\.env'
    if (-not (Test-Path -LiteralPath $dotenv)) { return $null }
    foreach ($line in Get-Content -LiteralPath $dotenv) {
        if (-not $line) { continue }
        $trim=$line.Trim()
        if (-not $trim -or $trim.StartsWith('#')) { continue }
        $prefix=$EnvName+'='
        if ($trim.StartsWith($prefix,[StringComparison]::Ordinal)) {
            $value=$trim.Substring($prefix.Length).Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value=$value.Substring(1,$value.Length-2)
            }
            if ($value) {
                [Environment]::SetEnvironmentVariable($EnvName,$value,'Process')
                return $value
            }
        }
    }
    return $null
}

function Remove-RoutePrefix([string]$Text) {
    $trim=$Text.Trim()
    # ASCII-safe construction for Windows PowerShell 5.1 reading UTF-8-no-BOM scripts.
    $throughWord = -join @([char]0x0447,[char]0x0435,[char]0x0440,[char]0x0435,[char]0x0437)
    $prefixes=@(
        ($throughWord+' API:'),($throughWord+' API '),($throughWord+' api:'),($throughWord+' api '),
        'API:','api:','API ','api ','Through API:','through api:','Via API:','via api:'
    )
    foreach ($prefix in $prefixes) {
        if ($trim.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
            return $trim.Substring($prefix.Length).Trim()
        }
    }
    return $trim
}

function Get-ResponseText($Response) {
    $parts=New-Object Collections.Generic.List[string]
    foreach ($item in @($Response.output)) {
        if ($null -eq $item) { continue }
        foreach ($content in @($item.content)) {
            if ($null -eq $content) { continue }
            if ($content.type -eq 'output_text' -and $content.text) { $parts.Add([string]$content.text) }
        }
    }
    return ($parts -join [Environment]::NewLine).Trim()
}

$root=Resolve-RepoRoot $ProjectPath
$routeJson=& $Router -Task $Task | Out-String
$route=$routeJson | ConvertFrom-Json
if ($route.route -ne 'EXTERNAL_API') {
    throw 'External worker refused execution: task is not explicitly routed through API. Prefix the task with "API:" or the configured Russian equivalent.'
}

if (-not $ProviderConfig) { $ProviderConfig=Get-DefaultProviderConfigPath }
if (-not (Test-Path -LiteralPath $ProviderConfig)) {
    throw "External provider is not configured. Expected local config: $ProviderConfig"
}
$config=Get-Content -LiteralPath $ProviderConfig -Raw | ConvertFrom-Json
if ([string]$config.mode -ne 'MANUAL_ONLY') { throw 'Provider config must remain MANUAL_ONLY until explicitly changed by the user.' }
if ([string]$config.status -ne 'CONFIGURED') { throw "Provider status is not CONFIGURED: $($config.status)" }
if ([string]$config.wire_api -ne 'responses') { throw 'This worker currently supports only the Responses API.' }
if (-not $config.base_url) { throw 'Provider base_url is missing.' }
if (-not $config.api_key_env) { throw 'Provider api_key_env is missing.' }
if (-not $Model) { $Model=[string]$config.default_model }
if (-not $Model) { throw 'No external model configured.' }

$key=Import-KeyFromCodexEnv ([string]$config.api_key_env)
if (-not $key) { throw "API key environment variable not available: $($config.api_key_env)" }

$gateOutput=& $Gate -ProjectPath $root -Task $Task -Files $Files 2>&1
$gateCode=$LASTEXITCODE
if ($gateCode -ne 0) {
    & $Ledger -Action record -ProjectPath $root -Provider ([string]$config.provider_name) -Model $Model -Outcome blocked -Task $Task -Notes 'Sensitive Data Gate blocked external transmission.'
    Write-Host $gateOutput
    throw 'External transmission blocked by Sensitive Data Gate. Sanitize or narrow the packet.'
}

$packetDir=Join-Path $root '.ai\external-api'
New-Item -ItemType Directory -Force -Path $packetDir | Out-Null
$packetPath=Join-Path $packetDir 'task-packet.generated.md'
& $PacketBuilder -ProjectPath $root -Task (Remove-RoutePrefix $Task) -Files $Files -OutputPath $packetPath | Out-Null
$packet=Get-Content -LiteralPath $packetPath -Raw

$base=[string]$config.base_url
$base=$base.TrimEnd('/')
$uri=$base+'/responses'
$headers=@{
    'Authorization'='Bearer '+$key
    'Content-Type'='application/json'
}
if ($config.http_headers) {
    foreach ($prop in $config.http_headers.PSObject.Properties) {
        $headers[[string]$prop.Name]=[string]$prop.Value
    }
}

$body=[ordered]@{
    model=$Model
    input=$packet
    store=$false
}
$bodyJson=$body | ConvertTo-Json -Depth 8
$watch=[Diagnostics.Stopwatch]::StartNew()
try {
    $response=Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $bodyJson -TimeoutSec $TimeoutSec
    $watch.Stop()
    $usage=$response.usage
    $inputTokens=if ($usage -and $usage.input_tokens) { [int64]$usage.input_tokens } else { 0 }
    $outputTokens=if ($usage -and $usage.output_tokens) { [int64]$usage.output_tokens } else { 0 }
    $cachedTokens=0
    if ($usage -and $usage.input_tokens_details -and $usage.input_tokens_details.cached_tokens) { $cachedTokens=[int64]$usage.input_tokens_details.cached_tokens }
    $reasoningTokens=0
    if ($usage -and $usage.output_tokens_details -and $usage.output_tokens_details.reasoning_tokens) { $reasoningTokens=[int64]$usage.output_tokens_details.reasoning_tokens }
    $multiplier=if ($null -ne $config.vendor_multiplier) { [double]$config.vendor_multiplier } else { 1.0 }
    & $Ledger -Action record -ProjectPath $root -Provider ([string]$config.provider_name) -Model $Model -InputTokens $inputTokens -OutputTokens $outputTokens -ReasoningTokens $reasoningTokens -CachedTokens $cachedTokens -VendorMultiplier $multiplier -DurationSeconds $watch.Elapsed.TotalSeconds -Outcome completed -Task (Remove-RoutePrefix $Task) -Notes ("response_id="+[string]$response.id) | Out-Null
    $text=Get-ResponseText $response
    if (-not $text) { throw 'External API completed but returned no output_text.' }
    Write-Output $text
}
catch {
    if ($watch.IsRunning) { $watch.Stop() }
    try {
        & $Ledger -Action record -ProjectPath $root -Provider ([string]$config.provider_name) -Model $Model -VendorMultiplier (if ($null -ne $config.vendor_multiplier) { [double]$config.vendor_multiplier } else { 1.0 }) -DurationSeconds $watch.Elapsed.TotalSeconds -Outcome failed -Task (Remove-RoutePrefix $Task) -Notes $_.Exception.Message | Out-Null
    } catch { }
    throw
}
