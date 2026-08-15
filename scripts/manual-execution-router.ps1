[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Task
)

$ErrorActionPreference = 'Stop'

$normalized = $Task.Trim()
$route = 'CODEX'
$reason = 'No explicit external/local route requested; MANUAL mode defaults to trusted Codex.'

if ($normalized -match '^(?is)\s*(через\s+api|through\s+api|via\s+api)\s*[:\-–—]?') {
    $route = 'EXTERNAL_API'
    $reason = 'User explicitly requested external API processing.'
}
elif ($normalized -match '^(?is)\s*(через\s+ollama|through\s+ollama|via\s+ollama)\s*[:\-–—]?') {
    $route = 'OLLAMA'
    $reason = 'User explicitly requested local Ollama processing.'
}
elif ($normalized -match '^(?is)\s*(через\s+codex|through\s+codex|via\s+codex)\s*[:\-–—]?') {
    $route = 'CODEX'
    $reason = 'User explicitly requested trusted Codex processing.'
}

[pscustomobject]@{
    mode = 'MANUAL_ONLY'
    route = $route
    reason = $reason
    externalConfigured = $false
} | ConvertTo-Json -Depth 3
