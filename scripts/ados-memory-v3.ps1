[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('regression-add','regression-search','decisions','negative-add','negative-search','all')]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [string]$Task = '',
    [string]$Fingerprint = '',
    [string]$RegressionCommand = '',
    [string[]]$Files = @(),
    [string]$Attempt = '',
    [string]$Outcome = '',
    [bool]$EvidenceChanged = $false,
    [int]$MaxResults = 20
)

$ErrorActionPreference = 'Stop'
$Common = Join-Path $PSScriptRoot 'ados-common.ps1'
. $Common

function Get-AdosRegressionPath {
    param([string]$Root)
    return Join-Path $Root '.ai\memory\regression-memory.json'
}

function Get-AdosNegativePath {
    param([string]$Root)
    return Join-Path $Root '.ai\memory\negative-memory.json'
}

function Test-AdosSafeRegressionCommand {
    param([string]$Value)
    if (-not $Value) { return $false }
    return [bool]($Value -match '(?i)^(git\s+(diff|status|grep)(?:\s+[^\r\n]+)?|npm\s+(test|run\s+[a-z0-9:_-]+)(?:\s+[^\r\n]+)?|pnpm\s+(test|run\s+[a-z0-9:_-]+)(?:\s+[^\r\n]+)?|yarn\s+(test|run\s+[a-z0-9:_-]+)(?:\s+[^\r\n]+)?|pytest(?:\s+[^\r\n]+)?|dotnet\s+test(?:\s+[^\r\n]+)?|go\s+test(?:\s+[^\r\n]+)?|cargo\s+test(?:\s+[^\r\n]+)?|powershell(?:\.exe)?\s+-[^\r\n]+-File\s+[^\r\n]+)$')
}

function Add-AdosRegression {
    param([string]$Root, [string]$TaskText, [string]$ErrorId, [string]$CheckCommand, [string[]]$RelatedFiles)

    if (-not $TaskText) { throw 'Task is required for regression-add.' }
    if (-not (Test-AdosSafeRegressionCommand $CheckCommand)) { throw 'RegressionCommand must use an approved deterministic test command.' }
    $path = Get-AdosRegressionPath $Root
    $memory = Read-AdosJson $path $null
    $entries = @()
    if ($memory -and $memory.entries) { $entries = @($memory.entries) }
    $idBasis = $TaskText + '|' + $ErrorId + '|' + $CheckCommand + '|' + ($RelatedFiles -join '|')
    $id = (Get-AdosTextHash $idBasis).Substring(0, 20)
    $entries = @($entries | Where-Object { [string]$_.id -ne $id })
    $entries += [pscustomobject]@{
        id = $id
        created = (Get-Date -Format o)
        task = $TaskText
        fingerprint = $ErrorId
        command = $CheckCommand
        files = @($RelatedFiles | ForEach-Object { ([string]$_).Replace('/', '\') } | Sort-Object -Unique)
        head = Get-AdosHead $Root
    }
    Write-AdosJson $path ([ordered]@{ schemaVersion=1; entries=@($entries | Sort-Object created -Descending) }) 10
    Write-Host "Regression memory added: $id"
    return $entries | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1
}

function Get-AdosMemoryScore {
    param($Entry, [string[]]$Terms, [string]$ErrorId, [string[]]$ChangedFiles)

    $score = 0
    if ($ErrorId -and [string]$Entry.fingerprint -eq $ErrorId) { $score += 100 }
    $taskValue = ''
    $attemptValue = ''
    $outcomeValue = ''
    if ($Entry.PSObject.Properties['task']) { $taskValue = [string]$Entry.task }
    if ($Entry.PSObject.Properties['attempt']) { $attemptValue = [string]$Entry.attempt }
    if ($Entry.PSObject.Properties['outcome']) { $outcomeValue = [string]$Entry.outcome }
    $text = ($taskValue + ' ' + $attemptValue + ' ' + $outcomeValue).ToLowerInvariant()
    foreach ($term in $Terms) { if ($text.Contains($term)) { $score += 8 } }
    foreach ($file in @($Entry.files)) {
        $normalized = ([string]$file).Replace('/', '\')
        if ($ChangedFiles -contains $normalized) { $score += 20 }
        foreach ($term in $Terms) { if ($normalized.ToLowerInvariant().Contains($term)) { $score += 4 } }
    }
    return $score
}

function Find-AdosRegressions {
    param([string]$Root, [string]$TaskText, [string]$ErrorId, [int]$Limit)

    $memory = Read-AdosJson (Get-AdosRegressionPath $Root) $null
    $entries = @()
    if ($memory -and $memory.entries) { $entries = @($memory.entries) }
    $terms = @(Get-AdosTaskTerms $TaskText)
    $changed = @(Get-AdosChangedFiles $Root)
    $ranked = @()
    foreach ($entry in $entries) {
        $score = Get-AdosMemoryScore $entry $terms $ErrorId $changed
        if ($score -gt 0) { $ranked += [pscustomobject]@{ score=$score; entry=$entry } }
    }
    $ranked = @($ranked | Sort-Object -Property @{Expression='score';Descending=$true} | Select-Object -First $Limit)
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        task = $TaskText
        fingerprint = $ErrorId
        matches = @($ranked | ForEach-Object { [pscustomobject]@{ score=$_.score; regression=$_.entry } })
    }
    Write-AdosJson (Join-Path $Root '.ai\context\regression-context.generated.json') $payload 10
    $lines = @('# ADOS regression context','',"Task: $TaskText",'', '## Required regression checks')
    foreach ($match in $ranked) {
        $entry = $match.entry
        $lines += "- ``$($entry.command)`` - score $($match.score) - $($entry.task)"
    }
    if ($ranked.Count -eq 0) { $lines += '- none' }
    Write-AdosUtf8 (Join-Path $Root '.ai\context\regression-context.generated.md') ($lines -join "`r`n")
    Write-Host "Regression memory matches: $($ranked.Count)"
    return $payload
}

function Get-AdosDecisionDocuments {
    param([string]$Root)

    $paths = @()
    $fixed = @('.ai\context\decisions.md','DECISIONS.md','docs\decisions.md')
    foreach ($relative in $fixed) {
        $full = Join-Path $Root $relative
        if (Test-Path -LiteralPath $full -PathType Leaf) { $paths += $full }
    }
    foreach ($folder in @('docs\adr','docs\adrs','adr','adrs')) {
        $fullFolder = Join-Path $Root $folder
        if (Test-Path -LiteralPath $fullFolder -PathType Container) {
            $paths += @(Get-ChildItem -LiteralPath $fullFolder -File -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
    }
    return @($paths | Sort-Object -Unique)
}

function Get-AdosDecisionIndex {
    param([string]$Root)

    $entries = @()
    foreach ($path in @(Get-AdosDecisionDocuments $Root)) {
        $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $titleMatch = [regex]::Match($content, '(?m)^#\s+(.+)$')
        $title = if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim() } else { [IO.Path]::GetFileNameWithoutExtension($path) }
        $statusMatch = [regex]::Match($content, '(?im)^status\s*:\s*(.+)$')
        $status = if ($statusMatch.Success) { $statusMatch.Groups[1].Value.Trim() } else { 'unspecified' }
        $terms = @(Get-AdosTaskTerms ($title + ' ' + $content))
        $entries += [pscustomobject]@{
            path = Get-AdosRelativePath $Root $path
            title = $title
            status = $status
            terms = @($terms)
            hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        head = Get-AdosHead $Root
        decisions = @($entries)
    }
    Write-AdosJson (Join-Path $Root '.ai\memory\decision-index.json') $payload 8
    return $payload
}

function Find-AdosDecisions {
    param([string]$Root, [string]$TaskText, [int]$Limit)

    $index = Get-AdosDecisionIndex $Root
    $terms = @(Get-AdosTaskTerms $TaskText)
    $ranked = @()
    foreach ($entry in @($index.decisions)) {
        $score = 0
        foreach ($term in $terms) {
            if (@($entry.terms) -contains $term) { $score += 5 }
            if (([string]$entry.title).ToLowerInvariant().Contains($term)) { $score += 10 }
        }
        if ($score -gt 0 -or $terms.Count -eq 0) { $ranked += [pscustomobject]@{ score=$score; entry=$entry } }
    }
    $ranked = @($ranked | Sort-Object -Property @{Expression='score';Descending=$true} | Select-Object -First $Limit)
    $negative = @(Find-AdosNegativeEntries $Root $TaskText '' $Limit)
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        task = $TaskText
        decisions = @($ranked | ForEach-Object { [pscustomobject]@{ score=$_.score; decision=$_.entry } })
        negativeMemory = @($negative)
    }
    Write-AdosJson (Join-Path $Root '.ai\context\decision-context.generated.json') $payload 10
    $lines = @('# ADOS decision and negative memory context','',"Task: $TaskText",'', '## Related decisions')
    foreach ($match in $ranked) { $lines += "- ``$($match.entry.path)`` - $($match.entry.title) - status $($match.entry.status) - score $($match.score)" }
    if ($ranked.Count -eq 0) { $lines += '- none' }
    $lines += @('','## Do not retry without changed evidence')
    foreach ($entry in $negative) { $lines += "- $($entry.attempt) - outcome: $($entry.outcome)" }
    if ($negative.Count -eq 0) { $lines += '- none' }
    Write-AdosUtf8 (Join-Path $Root '.ai\context\decision-context.generated.md') ($lines -join "`r`n")
    Write-Host "Decision context: $($ranked.Count) decisions, $($negative.Count) negative memories"
    return $payload
}

function Add-AdosNegativeEntry {
    param([string]$Root, [string]$TaskText, [string]$AttemptText, [string]$OutcomeText, [string[]]$RelatedFiles, [bool]$ChangedEvidence)

    if (-not $TaskText -or -not $AttemptText -or -not $OutcomeText) { throw 'Task, Attempt, and Outcome are required for negative-add.' }
    $path = Get-AdosNegativePath $Root
    $memory = Read-AdosJson $path $null
    $entries = @()
    if ($memory -and $memory.entries) { $entries = @($memory.entries) }
    $id = (Get-AdosTextHash ($TaskText + '|' + $AttemptText)).Substring(0, 20)
    $entries = @($entries | Where-Object { [string]$_.id -ne $id })
    $entries += [pscustomobject]@{
        id = $id
        created = (Get-Date -Format o)
        task = $TaskText
        attempt = $AttemptText
        outcome = $OutcomeText
        files = @($RelatedFiles)
        evidenceChanged = $ChangedEvidence
        retryPolicy = if ($ChangedEvidence) { 'review new evidence before retry' } else { 'do not retry unless evidence changes' }
        head = Get-AdosHead $Root
    }
    Write-AdosJson $path ([ordered]@{ schemaVersion=1; entries=@($entries | Sort-Object created -Descending) }) 10
    Write-Host "Negative memory added: $id"
}

function Find-AdosNegativeEntries {
    param([string]$Root, [string]$TaskText, [string]$ErrorId, [int]$Limit)

    $memory = Read-AdosJson (Get-AdosNegativePath $Root) $null
    $entries = @()
    if ($memory -and $memory.entries) { $entries = @($memory.entries) }
    $terms = @(Get-AdosTaskTerms $TaskText)
    $changed = @(Get-AdosChangedFiles $Root)
    $ranked = @()
    foreach ($entry in $entries) {
        $score = Get-AdosMemoryScore $entry $terms $ErrorId $changed
        if ($score -gt 0 -or $terms.Count -eq 0) { $ranked += [pscustomobject]@{ score=$score; value=$entry } }
    }
    return @($ranked | Sort-Object -Property @{Expression='score';Descending=$true} | Select-Object -First $Limit | ForEach-Object { $_.value })
}

function Write-AdosNegativeContext {
    param([string]$Root, [string]$TaskText, [int]$Limit)
    $entries = @(Find-AdosNegativeEntries $Root $TaskText $Fingerprint $Limit)
    $payload = [ordered]@{ schemaVersion=1; generated=(Get-Date -Format o); task=$TaskText; entries=@($entries) }
    Write-AdosJson (Join-Path $Root '.ai\context\negative-memory.generated.json') $payload 10
    $lines = @('# ADOS negative memory','',"Task: $TaskText",'', '## Do not retry without changed evidence')
    foreach ($entry in $entries) { $lines += "- $($entry.attempt) - $($entry.outcome) - $($entry.retryPolicy)" }
    if ($entries.Count -eq 0) { $lines += '- none' }
    Write-AdosUtf8 (Join-Path $Root '.ai\context\negative-memory.generated.md') ($lines -join "`r`n")
    Write-Host "Negative memory matches: $($entries.Count)"
}

$root = Resolve-AdosRepoRoot $ProjectPath
Ensure-AdosLocalExclude $root
switch ($Command) {
    'regression-add' { $null = Add-AdosRegression $root $Task $Fingerprint $RegressionCommand $Files }
    'regression-search' { $null = Find-AdosRegressions $root $Task $Fingerprint $MaxResults }
    'decisions' { $null = Find-AdosDecisions $root $Task $MaxResults }
    'negative-add' { Add-AdosNegativeEntry $root $Task $Attempt $Outcome $Files $EvidenceChanged }
    'negative-search' { Write-AdosNegativeContext $root $Task $MaxResults }
    'all' {
        $null = Find-AdosRegressions $root $Task $Fingerprint $MaxResults
        $null = Find-AdosDecisions $root $Task $MaxResults
    }
}
