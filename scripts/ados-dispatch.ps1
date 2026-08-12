[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('run','status','complete','release')]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [string]$QueueId = '',
    [string]$LeaseId = '',
    [ValidateSet('completed','failed','blocked')]
    [string]$ResultStatus = 'completed',
    [string]$ResultNote = '',
    [ValidateRange(10,720)]
    [int]$LeaseMinutes = 120,
    [ValidateRange(1,10)]
    [int]$MaxAttempts = 3,
    [ValidateRange(100,20000)]
    [int]$MaxFiles = 2000,
    [bool]$PrepareContext = $true,
    [bool]$UseOllama = $true
)

$ErrorActionPreference = 'Stop'
$Common = Join-Path $PSScriptRoot 'ados-common.ps1'
$DevCore = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\devcore.ps1'))
$Ados = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\ados.ps1'))
. $Common

function Get-AdosDispatchProperty {
    param($Value, [string]$Name, $DefaultValue = $null)
    if (-not $Value) { return $DefaultValue }
    if (@($Value.PSObject.Properties.Name) -contains $Name) { return $Value.$Name }
    return $DefaultValue
}

function ConvertTo-AdosDispatchTask {
    param($TaskValue, [hashtable]$Changes = @{})

    $payload = [ordered]@{
        id = [string](Get-AdosDispatchProperty $TaskValue 'id' '')
        created = [string](Get-AdosDispatchProperty $TaskValue 'created' '')
        updated = [string](Get-AdosDispatchProperty $TaskValue 'updated' '')
        task = [string](Get-AdosDispatchProperty $TaskValue 'task' '')
        priority = [string](Get-AdosDispatchProperty $TaskValue 'priority' 'normal')
        status = [string](Get-AdosDispatchProperty $TaskValue 'status' 'pending')
        attempts = [int](Get-AdosDispatchProperty $TaskValue 'attempts' 0)
        note = [string](Get-AdosDispatchProperty $TaskValue 'note' '')
        route = [string](Get-AdosDispatchProperty $TaskValue 'route' '')
        leaseId = [string](Get-AdosDispatchProperty $TaskValue 'leaseId' '')
        leaseOwner = [string](Get-AdosDispatchProperty $TaskValue 'leaseOwner' '')
        leaseUntil = [string](Get-AdosDispatchProperty $TaskValue 'leaseUntil' '')
        nextAttemptAfter = [string](Get-AdosDispatchProperty $TaskValue 'nextAttemptAfter' '')
        lastError = [string](Get-AdosDispatchProperty $TaskValue 'lastError' '')
        lastResult = [string](Get-AdosDispatchProperty $TaskValue 'lastResult' '')
    }
    foreach ($key in $Changes.Keys) { $payload[$key] = $Changes[$key] }
    return [pscustomobject]$payload
}

function Get-AdosDispatchQueuePath {
    param([string]$Root)
    return Join-Path $Root '.ai\queue\tasks.json'
}

function Read-AdosDispatchQueue {
    param([string]$Root)
    $queue = Read-AdosJson (Get-AdosDispatchQueuePath $Root) $null
    if (-not $queue) { return [pscustomobject]@{ schemaVersion=2; tasks=@() } }
    return $queue
}

function Write-AdosDispatchQueue {
    param([string]$Root, [object[]]$Tasks)

    $path = Get-AdosDispatchQueuePath $Root
    $temporary = "$path.$PID.tmp"
    Write-AdosJson $temporary ([ordered]@{ schemaVersion=2; updated=(Get-Date -Format o); tasks=@($Tasks) }) 12
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Test-AdosDispatchDateReached {
    param([string]$Value, [DateTimeOffset]$Now)
    if (-not $Value) { return $true }
    try { return [DateTimeOffset]::Parse($Value) -le $Now } catch { return $true }
}

function Write-AdosDispatchReport {
    param([string]$Root, [string]$State, $SelectedTask, [string]$Message, [hashtable]$Details = @{})

    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        state = $State
        message = $Message
        queueId = $(if ($SelectedTask) { [string]$SelectedTask.id } else { '' })
        leaseId = $(if ($SelectedTask) { [string]$SelectedTask.leaseId } else { '' })
        leaseUntil = $(if ($SelectedTask) { [string]$SelectedTask.leaseUntil } else { '' })
        route = $(if ($SelectedTask) { [string]$SelectedTask.route } else { '' })
        task = $(if ($SelectedTask) { [string]$SelectedTask.task } else { '' })
        priority = $(if ($SelectedTask) { [string]$SelectedTask.priority } else { '' })
        attempts = $(if ($SelectedTask) { [int]$SelectedTask.attempts } else { 0 })
        details = [pscustomobject]$Details
        safety = @(
            'At most one queue item is leased at a time.',
            'Ollama is optional, bounded, read-only, and never receives protected tasks.',
            'Codex remains responsible for code changes, evidence, and protected-domain review.',
            'The dispatcher never merges, deploys, changes production, or approves its own result.'
        )
    }
    Write-AdosJson (Join-Path $Root '.ai\queue\dispatch.generated.json') $payload 12
    $lines = @(
        '# ADOS autonomous dispatcher', '', "State: $State", "Message: $Message",
        "Queue ID: $($payload.queueId)", "Route: $($payload.route)", "Priority: $($payload.priority)",
        "Lease: $($payload.leaseId)", "Lease until: $($payload.leaseUntil)", '', '## Task', '',
        $(if ($payload.task) { $payload.task } else { 'No task selected.' }), '', '## Agent contract',
        '1. Read AGENTS.md, the prompt packet, elastic context, and this dispatch state.',
        '2. Treat any Ollama result as untrusted read-only advice.',
        '3. Use Codex for all edits, architecture, security, auth, SQL, RLS, finance, dependencies, releases, and production.',
        '4. Run Scope Guard, Verification Ladder, Evidence Gate, and create only a Draft PR.',
        '5. Never merge, deploy, expose secrets, or perform an externally visible action without explicit user authorization.',
        '6. Complete or release the exact lease after the run; never silently abandon a claimed task.'
    )
    Write-AdosUtf8 (Join-Path $Root '.ai\queue\dispatch.generated.md') ($lines -join "`r`n")
    return [pscustomobject]$payload
}

function Update-AdosClaimedTask {
    param([string]$Root, [string]$Id, [string]$ExpectedLease, [string]$NewStatus, [string]$Message, [switch]$ReturnToQueue)

    $lockPath = Enter-AdosQueueLock $Root
    try {
        $queue = Read-AdosDispatchQueue $Root
        $tasks = @()
        $updated = $null
        foreach ($item in @($queue.tasks)) {
            if ([string]$item.id -eq $Id) {
                if ([string](Get-AdosDispatchProperty $item 'status' '') -ne 'claimed') { throw "Queue task is not claimed: $Id" }
                if ([string](Get-AdosDispatchProperty $item 'leaseId' '') -ne $ExpectedLease) { throw "Lease mismatch for queue task: $Id" }
                $status = if ($ReturnToQueue) { 'pending' } else { $NewStatus }
                $updated = ConvertTo-AdosDispatchTask $item @{
                    updated=(Get-Date -Format o); status=$status; leaseId=''; leaseOwner=''; leaseUntil='';
                    nextAttemptAfter=''; lastResult=$Message; lastError=$(if ($NewStatus -eq 'failed') { $Message } else { '' })
                }
                $tasks += $updated
            }
            else { $tasks += (ConvertTo-AdosDispatchTask $item) }
        }
        if (-not $updated) { throw "Queue task not found: $Id" }
        Write-AdosDispatchQueue $Root $tasks
        return $updated
    }
    finally { Exit-AdosQueueLock $lockPath }
}

function Invoke-AdosDispatchRun {
    param([string]$Root)

    $now = [DateTimeOffset]::UtcNow
    $lockPath = Enter-AdosQueueLock $Root
    try {
        $queue = Read-AdosDispatchQueue $Root
        $tasks = @()
        foreach ($item in @($queue.tasks)) {
            $status = [string](Get-AdosDispatchProperty $item 'status' 'pending')
            $leaseUntil = [string](Get-AdosDispatchProperty $item 'leaseUntil' '')
            if ($status -eq 'claimed' -and (Test-AdosDispatchDateReached $leaseUntil $now)) {
                $tasks += (ConvertTo-AdosDispatchTask $item @{ status='pending'; leaseId=''; leaseOwner=''; leaseUntil=''; updated=(Get-Date -Format o); lastError='Previous dispatcher lease expired.' })
            }
            else { $tasks += (ConvertTo-AdosDispatchTask $item) }
        }
        $active = @($tasks | Where-Object { $_.status -eq 'claimed' -and -not (Test-AdosDispatchDateReached $_.leaseUntil $now) })
        if ($active.Count -gt 0) {
            $report = Write-AdosDispatchReport $Root 'BUSY' $active[0] 'An active queue lease already exists.'
            Write-Host "Dispatcher: BUSY ($($report.queueId))"
            return $report
        }
        $rank = @{ protected=0; high=1; normal=2; low=3 }
        $candidates = @($tasks | Where-Object {
            $_.status -eq 'pending' -and (Test-AdosDispatchDateReached $_.nextAttemptAfter $now)
        } | ForEach-Object {
            [pscustomobject]@{ rank=$(if ($rank.ContainsKey($_.priority)) { $rank[$_.priority] } else { 2 }); task=$_ }
        } | Sort-Object rank, @{Expression={$_.task.created};Descending=$false})
        if ($candidates.Count -eq 0) {
            Write-AdosDispatchQueue $Root $tasks
            $report = Write-AdosDispatchReport $Root 'EMPTY' $null 'No eligible pending queue task exists.'
            Write-Host 'Dispatcher: EMPTY'
            return $report
        }
        $selected = $candidates[0].task
        $route = if ([string]$selected.priority -eq 'protected') {
            'CODEX_REQUIRED'
        }
        else {
            (& $DevCore route -Task $selected.task | Out-String).Trim()
        }
        if (@('CODEX_REQUIRED','CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS','LOCAL_FIRST_THEN_CODEX_VERIFY') -notcontains $route) {
            throw "Unsupported dispatcher route: $route"
        }
        $lease = [guid]::NewGuid().ToString('N')
        $owner = "$env:COMPUTERNAME`:$PID"
        $leased = ConvertTo-AdosDispatchTask $selected @{
            updated=(Get-Date -Format o); status='claimed'; attempts=([int]$selected.attempts + 1); route=$route;
            leaseId=$lease; leaseOwner=$owner; leaseUntil=$now.AddMinutes($LeaseMinutes).ToString('o'); lastError=''; lastResult=''
        }
        $updatedTasks = @()
        foreach ($item in $tasks) {
            if ($item.id -eq $selected.id) { $updatedTasks += $leased } else { $updatedTasks += $item }
        }
        Write-AdosDispatchQueue $Root $updatedTasks
    }
    finally { Exit-AdosQueueLock $lockPath }

    $preparationStatus = 'SKIP'
    $localStatus = 'SKIP'
    $localOutput = ''
    $localFiles = @()
    try {
        if ($PrepareContext) {
            & $Ados start -ProjectPath $Root -Task $leased.task -MaxFiles $MaxFiles
            $preparationStatus = 'PASS'
        }
        else { $preparationStatus = 'DISABLED' }

        if ($leased.route -eq 'LOCAL_FIRST_THEN_CODEX_VERIFY') {
            if (-not $UseOllama) { $localStatus = 'DISABLED' }
            elseif (-not (Get-Command ollama -ErrorAction SilentlyContinue)) { $localStatus = 'UNAVAILABLE' }
            else {
                $elastic = Read-AdosJson (Join-Path $Root '.ai\context\elastic-context.generated.json') $null
                if ($elastic) {
                    $localFiles = @($elastic.selectedFiles | ForEach-Object { [string]$_.path } | Where-Object { $_ } | Select-Object -First 8)
                }
                $runner = Join-Path $Root 'scripts\ai-local-task.ps1'
                if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { $localStatus = 'UNAVAILABLE' }
                else {
                    & $DevCore local -ProjectPath $Root -Task ("Read-only first pass for queued task: " + $leased.task) -Files $localFiles
                    $latest = Get-ChildItem -LiteralPath (Join-Path $Root '.ai\local-output') -File -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($latest) { $localOutput = Get-AdosRelativePath $Root $latest.FullName }
                    $localStatus = 'PASS'
                }
            }
        }
    }
    catch {
        $failure = $_.Exception.Message
        $returnToQueue = [int]$leased.attempts -lt $MaxAttempts
        $failedTask = Update-AdosClaimedTask $Root $leased.id $leased.leaseId $(if ($returnToQueue) { 'pending' } else { 'blocked' }) $failure -ReturnToQueue:$returnToQueue
        $state = if ($returnToQueue) { 'RETRY_PENDING' } else { 'BLOCKED' }
        $null = Write-AdosDispatchReport $Root $state $failedTask $failure @{ preparation=$preparationStatus; localModel=$localStatus }
        throw
    }

    $details = @{
        preparation = $preparationStatus
        localModel = $localStatus
        localOutput = $localOutput
        localFiles = @($localFiles)
        promptPacket = '.ai\context\prompt-packet.generated.md'
        elasticContext = '.ai\context\elastic-context.generated.md'
        evidenceGate = '.ai\evidence\evidence-gate.generated.md'
        completionCommand = ".\ados.ps1 dispatch -ProjectPath `"$Root`" -DispatchAction complete -QueueId `"$($leased.id)`" -DispatchLeaseId `"$($leased.leaseId)`" -DispatchResult completed"
    }
    $report = Write-AdosDispatchReport $Root 'READY_FOR_CODEX' $leased 'Task leased and prepared for the scheduled Codex agent.' $details
    Write-Host "Dispatcher: READY_FOR_CODEX ($($leased.id), $($leased.route))"
    return $report
}

$root = Resolve-AdosRepoRoot $ProjectPath
Ensure-AdosLocalExclude $root

switch ($Command) {
    'run' { $null = Invoke-AdosDispatchRun $root }
    'status' {
        $queue = Read-AdosDispatchQueue $root
        $claimed = @($queue.tasks | Where-Object { $_.status -eq 'claimed' })
        $pending = @($queue.tasks | Where-Object { $_.status -eq 'pending' })
        $selected = if ($claimed.Count -gt 0) { ConvertTo-AdosDispatchTask $claimed[0] } else { $null }
        $state = if ($claimed.Count -gt 0) { 'BUSY' } elseif ($pending.Count -gt 0) { 'PENDING' } else { 'IDLE' }
        $null = Write-AdosDispatchReport $root $state $selected "$($pending.Count) pending, $($claimed.Count) claimed." @{ pending=$pending.Count; claimed=$claimed.Count }
        Write-Host "Dispatcher: $state ($($pending.Count) pending, $($claimed.Count) claimed)"
    }
    'complete' {
        if (-not $QueueId -or -not $LeaseId) { throw 'QueueId and LeaseId are required for dispatch completion.' }
        $updated = Update-AdosClaimedTask $root $QueueId $LeaseId $ResultStatus $ResultNote
        $null = Write-AdosDispatchReport $root $ResultStatus.ToUpperInvariant() $updated "Queue task marked $ResultStatus." @{ resultNote=$ResultNote }
        Write-Host "Dispatcher: $QueueId -> $ResultStatus"
    }
    'release' {
        if (-not $QueueId -or -not $LeaseId) { throw 'QueueId and LeaseId are required to release a dispatch lease.' }
        $updated = Update-AdosClaimedTask $root $QueueId $LeaseId 'pending' $ResultNote -ReturnToQueue
        $null = Write-AdosDispatchReport $root 'RELEASED' $updated 'Lease released; task returned to pending.' @{ resultNote=$ResultNote }
        Write-Host "Dispatcher: $QueueId -> pending"
    }
}
