[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('preview','install','status','uninstall')]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$DailyAt = '03:00',

    [ValidateRange(100,20000)]
    [int]$MaxFiles = 2000,

    [ValidateRange(2,365)]
    [int]$HealthHistoryLimit = 90,

    [string]$TaskName = '',
    [switch]$ConfirmInstall,
    [switch]$ReplaceExisting,
    [switch]$ConfirmUninstall
)

$ErrorActionPreference = 'Stop'
$Common = Join-Path $PSScriptRoot 'ados-common.ps1'
. $Common

function Test-AdosWindowsPlatform {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-AdosSchedulerTaskName {
    param([string]$Root, [string]$RequestedName)

    if ($RequestedName) {
        if ($RequestedName.Length -gt 120 -or $RequestedName -notmatch '^ADOS-Night-[A-Za-z0-9._-]+$') {
            throw 'TaskName must start with ADOS-Night- and contain only letters, numbers, dot, underscore, or hyphen.'
        }
        return $RequestedName
    }
    $repository = [regex]::Replace((Split-Path $Root -Leaf), '[^A-Za-z0-9._-]', '-')
    $repository = $repository.Trim('-')
    if (-not $repository) { $repository = 'project' }
    if ($repository.Length -gt 60) { $repository = $repository.Substring(0, 60).TrimEnd('-') }
    $identity = Get-AdosTextHash ($Root.ToLowerInvariant())
    return "ADOS-Night-$repository-$($identity.Substring(0, 10))"
}

function Get-AdosSchedulerPlan {
    param([string]$Root, [string]$Name, [string]$Time, [int]$FileLimit, [int]$HistoryLimit)

    $devCoreRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $ados = Join-Path $devCoreRoot 'ados.ps1'
    if (-not (Test-Path -LiteralPath $ados -PathType Leaf)) { throw "ADOS entry point not found: $ados" }
    $powerShell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) { $powerShell = 'powershell.exe' }
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'RemoteSigned',
        '-File',
        ('"' + $ados + '"'),
        'night',
        '-ProjectPath',
        ('"' + $Root + '"'),
        '-MaxFiles',
        [string]$FileLimit,
        '-HealthHistoryLimit',
        [string]$HistoryLimit
    ) -join ' '
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        taskName = $Name
        schedule = "daily at $Time"
        executable = $powerShell
        arguments = $arguments
        workingDirectory = $devCoreRoot
        projectPath = $Root
        runAs = 'current interactive user'
        runLevel = 'Limited'
        logonType = 'Interactive'
        storesCredentials = $false
        modelCalls = 0
        productCodeChanges = 0
        maxFiles = $FileLimit
        healthHistoryLimit = $HistoryLimit
    }
}

function Write-AdosSchedulerReport {
    param([string]$Root, [string]$State, $Plan, [string]$Message, $TaskInfo = $null)

    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        state = $State
        message = $Message
        task = $Plan
        taskInfo = $TaskInfo
        safety = @(
            'Preview never changes Windows Task Scheduler.',
            'Install and uninstall require explicit confirmation flags.',
            'The task runs as the current interactive user with Limited privileges.',
            'No password, paid API, model call, or product-code mutation is configured.'
        )
    }
    Write-AdosJson (Join-Path $Root '.ai\analytics\night-scheduler.generated.json') $payload 10
    $lines = @(
        '# ADOS Night Mode scheduler',
        '',
        "State: $State",
        "Message: $Message",
        "Task: $($Plan.taskName)",
        "Schedule: $($Plan.schedule)",
        "Project: $($Plan.projectPath)",
        "Run level: $($Plan.runLevel)",
        "Logon type: $($Plan.logonType)",
        "Stores credentials: $($Plan.storesCredentials)",
        '',
        '## Safety',
        '- Preview does not change Windows Task Scheduler.',
        '- Install and uninstall require explicit confirmation flags.',
        '- The task uses the current interactive user with Limited privileges.',
        '- Night Mode performs deterministic local analysis without model calls or product-code changes.'
    )
    Write-AdosUtf8 (Join-Path $Root '.ai\analytics\night-scheduler.generated.md') ($lines -join "`r`n")
    return [pscustomobject]$payload
}

function Get-AdosScheduledTaskExact {
    param([string]$Name)

    $command = Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue
    if (-not $command) { throw 'Windows ScheduledTasks module is unavailable.' }
    return Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-AdosTaskInfoPayload {
    param($ScheduledTask)

    if (-not $ScheduledTask) { return $null }
    $info = $null
    try { $info = Get-ScheduledTaskInfo -InputObject $ScheduledTask -ErrorAction Stop } catch { $info = $null }
    return [pscustomobject][ordered]@{
        state = [string]$ScheduledTask.State
        lastRunTime = $(if ($info) { $info.LastRunTime } else { $null })
        nextRunTime = $(if ($info) { $info.NextRunTime } else { $null })
        lastTaskResult = $(if ($info) { $info.LastTaskResult } else { $null })
    }
}

$root = Resolve-AdosRepoRoot $ProjectPath
Ensure-AdosLocalExclude $root
$name = Get-AdosSchedulerTaskName $root $TaskName
$plan = Get-AdosSchedulerPlan $root $name $DailyAt $MaxFiles $HealthHistoryLimit

switch ($Command) {
    'preview' {
        $message = 'Preview only. Windows Task Scheduler was not changed.'
        $null = Write-AdosSchedulerReport $root 'PREVIEW' $plan $message
        Write-Host $message
        Write-Host "Task name: $name"
        Write-Host "Schedule: $($plan.schedule)"
        Write-Host 'To install later, rerun with install and -ConfirmInstall.'
    }
    'status' {
        if (-not (Test-AdosWindowsPlatform)) { throw 'Windows Task Scheduler is available only on Windows.' }
        $scheduledTask = Get-AdosScheduledTaskExact $name
        $state = if ($scheduledTask) { 'INSTALLED' } else { 'NOT_INSTALLED' }
        $message = if ($scheduledTask) { 'The exact ADOS task exists.' } else { 'The exact ADOS task does not exist.' }
        $info = Get-AdosTaskInfoPayload $scheduledTask
        $null = Write-AdosSchedulerReport $root $state $plan $message $info
        Write-Host "$state`: $name"
        if ($info) { Write-Host "State: $($info.state); next run: $($info.nextRunTime); last result: $($info.lastTaskResult)" }
    }
    'install' {
        if (-not $ConfirmInstall) { throw 'Installation blocked. Review preview, then pass -ConfirmInstall explicitly.' }
        if (-not (Test-AdosWindowsPlatform)) { throw 'Windows Task Scheduler is available only on Windows.' }
        foreach ($required in @('New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskPrincipal','New-ScheduledTaskSettingsSet','New-ScheduledTask','Register-ScheduledTask')) {
            if (-not (Get-Command $required -ErrorAction SilentlyContinue)) { throw "Windows ScheduledTasks command is unavailable: $required" }
        }
        $existing = Get-AdosScheduledTaskExact $name
        if ($existing -and -not $ReplaceExisting) {
            throw 'The exact task already exists. Refusing to overwrite it without -ReplaceExisting.'
        }
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        if (-not $currentUser) { throw 'Unable to resolve the current Windows user.' }
        $time = [DateTime]::ParseExact($DailyAt, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $action = New-ScheduledTaskAction -Execute $plan.executable -Argument $plan.arguments -WorkingDirectory $plan.workingDirectory
        $trigger = New-ScheduledTaskTrigger -Daily -At $time
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
        $definition = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "ADOS read-only Night Mode for $root"
        $registerParameters = @{ TaskName=$name; InputObject=$definition; ErrorAction='Stop' }
        if ($ReplaceExisting) { $registerParameters.Force = $true }
        $installed = Register-ScheduledTask @registerParameters
        $info = Get-AdosTaskInfoPayload $installed
        $null = Write-AdosSchedulerReport $root 'INSTALLED' $plan 'The exact ADOS task was installed.' $info
        Write-Host "INSTALLED: $name"
    }
    'uninstall' {
        if (-not $ConfirmUninstall) { throw 'Uninstall blocked. Pass -ConfirmUninstall explicitly.' }
        if (-not (Test-AdosWindowsPlatform)) { throw 'Windows Task Scheduler is available only on Windows.' }
        if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) { throw 'Windows ScheduledTasks module is unavailable.' }
        $existing = Get-AdosScheduledTaskExact $name
        if (-not $existing) {
            $null = Write-AdosSchedulerReport $root 'NOT_INSTALLED' $plan 'Nothing was removed because the exact task does not exist.'
            Write-Host "NOT_INSTALLED: $name"
            break
        }
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        $null = Write-AdosSchedulerReport $root 'REMOVED' $plan 'The exact ADOS task was removed.'
        Write-Host "REMOVED: $name"
    }
}
