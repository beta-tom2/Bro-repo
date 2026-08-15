[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Task
)

$ErrorActionPreference = 'Stop'

$normalized = $Task.Trim().ToLowerInvariant()
$route = 'CODEX'
$reason = 'No explicit external/local route requested; MANUAL mode defaults to trusted Codex.'

function Test-RoutePrefix {
    param(
        [string]$Text,
        [string[]]$Prefixes
    )
    foreach ($prefix in $Prefixes) {
        if ($Text.StartsWith($prefix)) { return $true }
    }
    return $false
}

$apiPrefixes = @(
    'через api',
    'api:',
    'api ',
    'through api',
    'via api'
)

$ollamaPrefixes = @(
    'через ollama',
    'ollama:',
    'ollama ',
    'through ollama',
    'via ollama'
)

$codexPrefixes = @(
    'через codex',
    'codex:',
    'codex ',
    'through codex',
    'via codex'
)

if (Test-RoutePrefix $normalized $apiPrefixes) {
    $route = 'EXTERNAL_API'
    $reason = 'User explicitly requested external API processing.'
}
elseif (Test-RoutePrefix $normalized $ollamaPrefixes) {
    $route = 'OLLAMA'
    $reason = 'User explicitly requested local Ollama processing.'
}
elseif (Test-RoutePrefix $normalized $codexPrefixes) {
    $route = 'CODEX'
    $reason = 'User explicitly requested trusted Codex processing.'
}

[pscustomobject]@{
    mode = 'MANUAL_ONLY'
    route = $route
    reason = $reason
    externalConfigured = $false
} | ConvertTo-Json -Depth 3
