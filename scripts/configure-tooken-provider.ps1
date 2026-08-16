[CmdletBinding()]
param(
    [string]$Model='gpt-5.6-sol',
    [double]$VendorMultiplier=1.0,
    [switch]$Force
)

$ErrorActionPreference='Stop'
$userHome=$env:USERPROFILE
if (-not $userHome) { $userHome=$HOME }
if (-not $userHome) { throw 'Cannot determine user home.' }

$dir=Join-Path $userHome '.albert-devcore'
$path=Join-Path $dir 'external-api-provider.json'
if ((Test-Path -LiteralPath $path) -and -not $Force) {
    throw "Provider config already exists: $path. Re-run with -Force only if you intentionally want to replace it."
}

New-Item -ItemType Directory -Force -Path $dir | Out-Null
$config=[ordered]@{
    mode='MANUAL_ONLY'
    status='CONFIGURED'
    provider_name='Tooken Club'
    base_url='https://tooken.club/v1'
    api_key_env='TOOKEN_API_KEY'
    wire_api='responses'
    default_model=$Model
    supports_usage=$true
    usage_endpoint=''
    vendor_multiplier=$VendorMultiplier
    http_headers=[ordered]@{
        'X-Token-Client'='codex'
    }
    limits=[ordered]@{
        rpm=$null
        tpm=$null
        context_tokens=$null
    }
    trust='LOW_TRUST_COMPUTE'
    notes='Manual-only external provider. API key remains in ~/.codex/.env or process environment; never store it here.'
}
$json=$config | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($path,$json,(New-Object Text.UTF8Encoding($false)))
Write-Host "Configured Tooken provider: $path"
Write-Host "Mode: MANUAL_ONLY"
Write-Host "Model: $Model"
Write-Host "Vendor multiplier: $VendorMultiplier"
Write-Host 'No API key was written to this config.'
