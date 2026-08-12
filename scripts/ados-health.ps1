[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [ValidateRange(2,365)]
    [int]$MaxHistory = 90
)

$ErrorActionPreference = 'Stop'
$Common = Join-Path $PSScriptRoot 'ados-common.ps1'
. $Common

function Get-AdosPropertyValue {
    param($Object, [string]$Name)

    if (-not $Object) { return $null }
    $property = @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
    if ($property.Count -eq 0 -or $null -eq $property[0].Value) { return $null }
    return ,$property[0].Value
}

function Get-AdosNumericProperty {
    param($Object, [string]$Name)

    $value = Get-AdosPropertyValue $Object $Name
    if ($null -eq $value) { return $null }
    $number = 0.0
    if (-not [double]::TryParse([string]$value, [ref]$number)) { return $null }
    return [double]$number
}

function Get-AdosHealthConfiguration {
    param([string]$Root, [int]$FallbackHistory)

    $defaults = [ordered]@{
        maxConflictMarkers = 0
        maxLargeSourceFiles = 50
        maxTodoMarkers = 500
        maxChangedFiles = 100
    }
    $supported = [ordered]@{
        maxConflictMarkers = [pscustomobject]@{ metric='conflictMarkers'; operator='max' }
        maxLargeSourceFiles = [pscustomobject]@{ metric='largeSourceFiles'; operator='max' }
        maxTodoMarkers = [pscustomobject]@{ metric='todoMarkers'; operator='max' }
        maxChangedFiles = [pscustomobject]@{ metric='changedFiles'; operator='max' }
        maxIndexUpdatedFiles = [pscustomobject]@{ metric='indexUpdatedFiles'; operator='max' }
        minIndexReusePercent = [pscustomobject]@{ metric='indexReusePercent'; operator='min' }
        maxFailedVerificationChecks = [pscustomobject]@{ metric='failedVerificationChecks'; operator='max' }
        minContextReductionPercent = [pscustomobject]@{ metric='contextReductionPercent'; operator='min' }
    }
    $thresholds = [ordered]@{}
    foreach ($name in $defaults.Keys) { $thresholds[$name] = [double]$defaults[$name] }
    $errors = @()
    $warnings = @()
    $source = 'built-in defaults'
    $historyLimit = $FallbackHistory
    $baselineWindow = 10
    $path = Join-Path $Root '.ados\health.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $config = Read-AdosJson $path $null
        if (-not $config) {
            $errors += 'Unable to parse .ados/health.json.'
        }
        else {
            $source = '.ados/health.json'
            $historyValue = Get-AdosNumericProperty $config 'historyLimit'
            if ($null -ne $historyValue) {
                if ($historyValue -lt 2 -or $historyValue -gt 365) { $errors += 'historyLimit must be between 2 and 365.' }
                else { $historyLimit = [int]$historyValue }
            }
            $windowValue = Get-AdosNumericProperty $config 'baselineWindow'
            if ($null -ne $windowValue) {
                if ($windowValue -lt 1 -or $windowValue -gt 90) { $errors += 'baselineWindow must be between 1 and 90.' }
                else { $baselineWindow = [int]$windowValue }
            }
            $configuredThresholds = Get-AdosPropertyValue $config 'thresholds'
            if ($configuredThresholds) {
                foreach ($property in @($configuredThresholds.PSObject.Properties)) {
                    $name = [string]$property.Name
                    if (-not $supported.Contains($name)) { $warnings += "Unknown threshold ignored: $name"; continue }
                    $number = 0.0
                    if (-not [double]::TryParse([string]$property.Value, [ref]$number) -or $number -lt 0) {
                        $errors += "Threshold must be a non-negative number: $name"
                        continue
                    }
                    if ($name -match 'Percent$' -and $number -gt 100) {
                        $errors += "Percentage threshold must not exceed 100: $name"
                        continue
                    }
                    $thresholds[$name] = [double]$number
                }
            }
        }
    }
    return [pscustomobject]@{
        source = $source
        path = $path
        thresholds = $thresholds
        supported = $supported
        historyLimit = $historyLimit
        baselineWindow = $baselineWindow
        errors = @($errors)
        warnings = @($warnings)
    }
}

function Get-AdosHealthMetrics {
    param([string]$Root)

    $audit = Read-AdosJson (Join-Path $Root '.ai\analytics\night-audit.generated.json') $null
    $index = Read-AdosJson (Join-Path $Root '.ai\index\hash-index.generated.json') $null
    $verification = Read-AdosJson (Join-Path $Root '.ai\evidence\verification.generated.json') $null
    $evidence = Read-AdosJson (Join-Path $Root '.ai\evidence\evidence-gate.generated.json') $null
    $benchmark = Read-AdosJson (Join-Path $Root '.ai\analytics\ab-benchmark.generated.json') $null
    $queue = Read-AdosJson (Join-Path $Root '.ai\queue\tasks.json') $null
    $currentHead = Get-AdosHead $Root
    $currentBranch = Get-AdosBranch $Root

    $auditMetrics = Get-AdosPropertyValue $audit 'metrics'
    $metrics = [ordered]@{}
    foreach ($name in @('sourceFiles','conflictMarkers','largeSourceFiles','todoMarkers','changedFiles')) {
        $value = Get-AdosNumericProperty $auditMetrics $name
        if ($null -ne $value) { $metrics[$name] = $value }
    }
    $indexStats = Get-AdosPropertyValue $index 'stats'
    if ($indexStats) {
        $scanned = Get-AdosNumericProperty $indexStats 'scanned'
        $reused = Get-AdosNumericProperty $indexStats 'reused'
        $updated = Get-AdosNumericProperty $indexStats 'updated'
        if ($null -eq $scanned) { $scanned = 0 }
        if ($null -eq $reused) { $reused = 0 }
        if ($null -ne $updated) { $metrics.indexUpdatedFiles = [double]$updated }
        $metrics.indexReusePercent = $(if ($scanned -gt 0) { [math]::Round(($reused * 100.0) / $scanned, 2) } else { 0 })
    }
    $evidenceCurrent = [bool]($evidence -and [string](Get-AdosPropertyValue $evidence 'head') -eq $currentHead -and [string](Get-AdosPropertyValue $evidence 'branch') -eq $currentBranch -and [string](Get-AdosPropertyValue $evidence 'evidenceFingerprint') -eq (Get-AdosEvidenceFingerprint $Root))
    $verificationChecks = Get-AdosPropertyValue $verification 'checks'
    if ($evidenceCurrent -and $verificationChecks) {
        $metrics.failedVerificationChecks = [double](@($verificationChecks | Where-Object { [string](Get-AdosPropertyValue $_ 'status') -eq 'FAIL' }).Count)
    }
    if ($benchmark -and [string](Get-AdosPropertyValue $benchmark 'head') -eq $currentHead -and [string](Get-AdosPropertyValue $benchmark 'branch') -eq $currentBranch) {
        $value = Get-AdosNumericProperty $benchmark 'contextByteReductionPercent'
        if ($null -ne $value) { $metrics.contextReductionPercent = $value }
    }
    $pending = 0
    $queueTasks = Get-AdosPropertyValue $queue 'tasks'
    if ($queueTasks) { $pending = @($queueTasks | Where-Object { [string](Get-AdosPropertyValue $_ 'status') -eq 'pending' }).Count }
    $metrics.pendingQueueTasks = [double]$pending
    return $metrics
}

function Get-AdosHealthChecks {
    param($Metrics, $Configuration)

    $checks = @()
    foreach ($name in $Configuration.thresholds.Keys) {
        $definition = $Configuration.supported[$name]
        $metricName = [string]$definition.metric
        if (-not $Metrics.Contains($metricName)) {
            $checks += [pscustomobject]@{ threshold=$name; metric=$metricName; operator=$definition.operator; value=$null; limit=$Configuration.thresholds[$name]; status='SKIP'; detail='metric unavailable' }
            continue
        }
        $value = [double]$Metrics[$metricName]
        $limit = [double]$Configuration.thresholds[$name]
        $passed = if ([string]$definition.operator -eq 'min') { $value -ge $limit } else { $value -le $limit }
        $checks += [pscustomobject]@{
            threshold = $name
            metric = $metricName
            operator = [string]$definition.operator
            value = $value
            limit = $limit
            status = $(if ($passed) { 'PASS' } else { 'FAIL' })
            detail = $(if ([string]$definition.operator -eq 'min') { "expected >= $limit" } else { "expected <= $limit" })
        }
    }
    return @($checks)
}

function Get-AdosHealthTrend {
    param($Metrics, [object[]]$PreviousSnapshots, [int]$Window)

    $trend = @()
    $recent = @($PreviousSnapshots | Select-Object -Last $Window)
    foreach ($name in $Metrics.Keys) {
        $values = @()
        foreach ($snapshot in $recent) {
            $value = Get-AdosNumericProperty (Get-AdosPropertyValue $snapshot 'metrics') $name
            if ($null -ne $value) { $values += [double]$value }
        }
        $previous = $null
        if ($values.Count -gt 0) { $previous = [double]$values[$values.Count - 1] }
        $baseline = $null
        if ($values.Count -gt 0) { $baseline = [math]::Round([double](($values | Measure-Object -Average).Average), 2) }
        $current = [double]$Metrics[$name]
        $change = 'new'
        $delta = $null
        if ($null -ne $previous) {
            $delta = [math]::Round($current - $previous, 2)
            $change = if ($delta -gt 0) { 'up' } elseif ($delta -lt 0) { 'down' } else { 'stable' }
        }
        $trend += [pscustomobject]@{
            metric = $name
            current = $current
            previous = $previous
            delta = $delta
            baseline = $baseline
            deltaFromBaseline = $(if ($null -ne $baseline) { [math]::Round($current - $baseline, 2) } else { $null })
            change = $change
        }
    }
    return @($trend)
}

$root = Resolve-AdosRepoRoot $ProjectPath
Ensure-AdosLocalExclude $root
$configuration = Get-AdosHealthConfiguration $root $MaxHistory
$metrics = Get-AdosHealthMetrics $root
$checks = Get-AdosHealthChecks $metrics $configuration
$failed = @($checks | Where-Object { [string]$_.status -eq 'FAIL' })
$status = if ($configuration.errors.Count -gt 0) { 'CONFIG_ERROR' } elseif ($failed.Count -gt 0) { 'ATTENTION' } else { 'HEALTHY' }

$historyPath = Join-Path $root '.ai\analytics\health-history.json'
$historyData = Read-AdosJson $historyPath $null
$snapshots = @()
$storedSnapshots = Get-AdosPropertyValue $historyData 'snapshots'
if ($storedSnapshots) { $snapshots = @($storedSnapshots) }
$trend = Get-AdosHealthTrend $metrics $snapshots $configuration.baselineWindow
$fingerprintBasis = (Get-AdosBranch $root) + '|' + (Get-AdosHead $root) + '|' + ($metrics | ConvertTo-Json -Compress -Depth 6) + '|' + ($configuration.thresholds | ConvertTo-Json -Compress -Depth 4)
$fingerprint = Get-AdosTextHash $fingerprintBasis
$snapshot = [ordered]@{
    generated = (Get-Date -Format o)
    fingerprint = $fingerprint
    branch = Get-AdosBranch $root
    head = Get-AdosHead $root
    status = $status
    metrics = $metrics
}
$recorded = $true
if ($snapshots.Count -gt 0 -and [string](Get-AdosPropertyValue $snapshots[$snapshots.Count - 1] 'fingerprint') -eq $fingerprint) {
    $snapshots[$snapshots.Count - 1] = [pscustomobject]$snapshot
    $recorded = $false
}
else { $snapshots += [pscustomobject]$snapshot }
if ($snapshots.Count -gt $configuration.historyLimit) { $snapshots = @($snapshots | Select-Object -Last $configuration.historyLimit) }
Write-AdosJson $historyPath ([ordered]@{ schemaVersion=1; updated=(Get-Date -Format o); snapshots=@($snapshots) }) 10

$payload = [ordered]@{
    schemaVersion = 1
    generated = (Get-Date -Format o)
    status = $status
    branch = $snapshot.branch
    head = $snapshot.head
    thresholdSource = $configuration.source
    thresholds = $configuration.thresholds
    configurationErrors = @($configuration.errors)
    configurationWarnings = @($configuration.warnings)
    metrics = $metrics
    checks = @($checks)
    failedChecks = $failed.Count
    trend = @($trend)
    historyCount = $snapshots.Count
    snapshotRecorded = $recorded
    historyLimit = $configuration.historyLimit
    baselineWindow = $configuration.baselineWindow
    safety = 'Local deterministic metrics only; no model or paid API was called.'
}
Write-AdosJson (Join-Path $root '.ai\analytics\health.generated.json') $payload 10

$lines = @(
    '# ADOS project health','',"Status: $status","Threshold source: $($configuration.source)",
    "History snapshots: $($snapshots.Count) of $($configuration.historyLimit)","Baseline window: $($configuration.baselineWindow)",'',
    '## Threshold checks','', '| Metric | Value | Rule | Result |','|---|---:|---|---|'
)
foreach ($check in $checks) {
    $value = if ($null -eq $check.value) { 'n/a' } else { [string]$check.value }
    $rule = if ([string]$check.operator -eq 'min') { ">= $($check.limit)" } else { "<= $($check.limit)" }
    $lines += "| $($check.metric) | $value | $rule | $($check.status) |"
}
$lines += @('','## Trend','', '| Metric | Current | Previous | Baseline | Change |','|---|---:|---:|---:|---|')
foreach ($item in $trend) {
    $previous = if ($null -eq $item.previous) { 'n/a' } else { [string]$item.previous }
    $baseline = if ($null -eq $item.baseline) { 'n/a' } else { [string]$item.baseline }
    $lines += "| $($item.metric) | $($item.current) | $previous | $baseline | $($item.change) |"
}
if ($configuration.errors.Count -gt 0) { $lines += @('','## Configuration errors'); $lines += @($configuration.errors | ForEach-Object { '- ' + [string]$_ }) }
if ($configuration.warnings.Count -gt 0) { $lines += @('','## Configuration warnings'); $lines += @($configuration.warnings | ForEach-Object { '- ' + [string]$_ }) }
$lines += @('','## Safety','- Metrics and history are local and advisory.','- No model or paid API was called.','- Project configuration was read but not modified.')
Write-AdosUtf8 (Join-Path $root '.ai\analytics\health.generated.md') ($lines -join "`r`n")
Add-AdosUsageEvent $root 'project-health' $status 0 0 0 @{ failedChecks=$failed.Count; history=$snapshots.Count; recorded=$recorded }
Write-Host "Project health: $status ($($failed.Count) failed thresholds, $($snapshots.Count) trend snapshots)"
