[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Fixture = Join-Path $RepoRoot 'tests\.work\ados-v3-smoke'
$FixtureParent = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'tests\.work'))
$ResolvedFixture = [IO.Path]::GetFullPath($Fixture)
if (-not $ResolvedFixture.StartsWith($FixtureParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to prepare a fixture outside tests\.work.'
}
Push-Location $RepoRoot
try { $outerExclude = (& git rev-parse --git-path info/exclude 2>$null | Out-String).Trim() }
finally { Pop-Location }
if (-not [IO.Path]::IsPathRooted($outerExclude)) { $outerExclude = Join-Path $RepoRoot $outerExclude }
$outerExclude = [IO.Path]::GetFullPath($outerExclude)
$outerRule = 'tests/.work/'
$outerExisting = if (Test-Path -LiteralPath $outerExclude) { @(Get-Content -LiteralPath $outerExclude) } else { @() }
if ($outerExisting -notcontains $outerRule) { Add-Content -LiteralPath $outerExclude -Value $outerRule -Encoding UTF8 }
if (Test-Path -LiteralPath $ResolvedFixture) { Remove-Item -LiteralPath $ResolvedFixture -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $ResolvedFixture 'src') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ResolvedFixture 'tests') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ResolvedFixture 'docs\adr') -Force | Out-Null

$encoding = New-Object System.Text.UTF8Encoding($false)
function Write-FixtureFile([string]$Relative, [string]$Content) {
    $path = Join-Path $ResolvedFixture $Relative
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($path, $Content, $encoding)
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Read-Json([string]$Relative) {
    return (Get-Content -LiteralPath (Join-Path $ResolvedFixture $Relative) -Raw | ConvertFrom-Json)
}

Write-FixtureFile 'README.md' ("# ADOS smoke fixture`r`n" + ('large optional documentation ' * 5000))
Write-FixtureFile 'src\friends.ts' "// friend request`r`nexport function sendFriendRequest(userId: string): string { return userId; }`r`n"
Write-FixtureFile 'src\friends-copy.ts' "// friend request`r`nexport function sendFriendRequest(userId: string): string { return userId; }`r`n"
Write-FixtureFile 'tests\friends.test.ts' "import { sendFriendRequest } from '../src/friends';`r`n"
Write-FixtureFile 'packages\social\package.json' '{"name":"social","type":"module","scripts":{"test":"node --test"}}'
Write-FixtureFile 'packages\social\src\friends.js' "export function normalizeFriend(value) { return value.trim(); }`r`n"
Write-FixtureFile 'packages\social\tests\friends.test.js' "import test from 'node:test';`r`nimport assert from 'node:assert/strict';`r`nimport { normalizeFriend } from '../src/friends.js';`r`ntest('normalizes a friend', () => assert.equal(normalizeFriend(' Ada '), 'Ada'));`r`n"
Write-FixtureFile 'packages\admin\package.json' '{"name":"admin","type":"module"}'
Write-FixtureFile 'packages\admin\tests\friends.test.js' "// normalizeFriend belongs to another workspace and must not create a cross-package association.`r`n"
Write-FixtureFile 'docs\adr\ADR-0001-friend-service.md' "# ADR-0001 Friend service boundary`r`n`r`nStatus: accepted`r`n`r`nFriend requests remain in the friend service.`r`n"
Write-FixtureFile 'docs\project-brain\README.md' "# Project Brain`r`n"
Write-FixtureFile 'docs\project-brain\CURRENT_FOCUS.md' "# Current focus`r`nFriend request safety.`r`n"
Write-FixtureFile 'docs\project-brain\AGENT_ENTRYPOINTS.md' "# Agent entrypoints`r`nStart with friends service.`r`n"
Write-FixtureFile '.ados\adapter.json' '{"name":"smoke-custom","protectedBoundaries":["custom boundary"],"contextEntrypoints":["docs/project-brain/README.md","docs/project-brain/CURRENT_FOCUS.md","docs/project-brain/AGENT_ENTRYPOINTS.md"]}'
Write-FixtureFile '.ados\health.json' '{"schemaVersion":1,"historyLimit":5,"baselineWindow":3,"thresholds":{"maxConflictMarkers":0,"maxLargeSourceFiles":0,"maxTodoMarkers":0,"maxChangedFiles":10}}'

Push-Location $ResolvedFixture
try {
    & git init -q
    & git config user.name 'ADOS Smoke Test'
    & git config user.email 'ados-smoke@example.invalid'
    & git add .
    & git commit -q -m 'test: seed fixture'
}
finally { Pop-Location }

$Index = Join-Path $RepoRoot 'scripts\ados-index.ps1'
$Quality = Join-Path $RepoRoot 'scripts\ados-quality.ps1'
$Memory = Join-Path $RepoRoot 'scripts\ados-memory-v3.ps1'
$Operations = Join-Path $RepoRoot 'scripts\ados-operations.ps1'
$Ados = Join-Path $RepoRoot 'ados.ps1'

& $Index all -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -MaxFiles 100
$first = Read-Json '.ai\index\hash-index.generated.json'
Assert-True ($first.stats.updated -ge 4) 'first index pass must analyze fixture files'
Assert-True ((Read-Json '.ai\index\symbol-index.generated.json').symbolCount -ge 1) 'symbol index must find sendFriendRequest'
$testMap = Read-Json '.ai\index\test-symbol-map.generated.json'
Assert-True (@($testMap.associations | Where-Object { $_.sourceFile -eq 'src\friends.ts' -and $_.testFile -eq 'tests\friends.test.ts' }).Count -eq 1) 'test map must connect a relative import to its source'
Assert-True (@($testMap.associations | Where-Object { $_.sourceFile -eq 'packages\social\src\friends.js' -and $_.testFile -eq 'packages\social\tests\friends.test.js' }).Count -eq 1) 'test map must preserve monorepo package associations'
Assert-True (@($testMap.associations | Where-Object { $_.sourceFile -eq 'packages\social\src\friends.js' -and $_.testFile -eq 'packages\admin\tests\friends.test.js' }).Count -eq 0) 'test map must reject ambiguous cross-package symbol matches'
Assert-True ((Read-Json '.ai\context\elastic-context.generated.json').selectedFiles.Count -ge 1) 'elastic context must select files'
$initialElastic = Read-Json '.ai\context\elastic-context.generated.json'
Assert-True (@($initialElastic.associatedTestFiles) -contains 'tests\friends.test.ts') 'elastic context must select the focused test associated with a relevant source'
Assert-True (@($initialElastic.selectedFiles.path) -contains 'docs\project-brain\README.md') 'elastic context must prioritize repository entrypoints'
Assert-True (@($initialElastic.selectedFiles.path) -notcontains 'README.md') 'oversized optional README must not consume elastic context budget'
Assert-True (@($initialElastic.skippedBaseFiles.path) -contains 'README.md') 'elastic context must report the skipped oversized README'
$selectedFriendCopies = @($initialElastic.selectedFiles.path | Where-Object { $_ -match '^src\\friends(?:-copy)?\.ts$' })
$skippedFriendCopies = @($initialElastic.skippedDuplicateFiles.path | Where-Object { $_ -match '^src\\friends(?:-copy)?\.ts$' })
Assert-True ($selectedFriendCopies.Count -eq 1) 'elastic context must select only one copy of identical source content'
Assert-True ($skippedFriendCopies.Count -eq 1) 'elastic context must report the skipped duplicate source file'
Assert-True ([long]$initialElastic.duplicateBytesAvoided -gt 0) 'elastic context must report duplicate bytes avoided'

& $Index index -ProjectPath $ResolvedFixture -MaxFiles 100
$second = Read-Json '.ai\index\hash-index.generated.json'
Assert-True ($second.stats.updated -eq 0) 'second index pass must not reanalyze unchanged files'
Assert-True ($second.stats.reused -eq $second.stats.scanned) 'second index pass must reuse every scanned file'

Write-FixtureFile 'packages\social\src\friends.js' "// focused verification change`r`nexport function normalizeFriend(value) { return value.trim(); }`r`n"
& $Ados verify -ProjectPath $ResolvedFixture -Task 'Verify social friend normalization' -AllowedScope @('packages\social') -MaxVerificationLevel 3 -RequireDiff $true -MaxFiles 100
$focusedVerification = Read-Json '.ai\evidence\verification.generated.json'
Assert-True ($focusedVerification.focusedTests.mapCurrent) 'verification must use a test map matching the current worktree'
Assert-True ($focusedVerification.focusedTests.executed) 'verification must execute bounded focused tests for a recognized package runner'
Assert-True (@($focusedVerification.checks | Where-Object { $_.name -match '^npm focused tests:' -and $_.status -eq 'PASS' }).Count -eq 1) 'focused package test must pass'
Assert-True ((Read-Json '.ai\evidence\pr-evidence-summary.generated.json').verification.focusedTests.executed) 'PR evidence must preserve focused-test execution'
Push-Location $ResolvedFixture
try { & git restore -- packages\social\src\friends.js }
finally { Pop-Location }

Push-Location $ResolvedFixture
try { $statusBeforeStart = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
& $Ados start -ProjectPath $ResolvedFixture -Task 'Prepare friend request review' -MaxFiles 100 -MaxCommits 20
Push-Location $ResolvedFixture
try { $statusAfterStart = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
Assert-True ($statusBeforeStart -eq $statusAfterStart) 'ADOS start must keep generated context out of product Git status'
$packet = Get-Content -LiteralPath (Join-Path $ResolvedFixture '.ai\context\prompt-packet.generated.md') -Raw
Assert-True ($packet -match 'docs\\project-brain\\README.md') 'prompt packet must include the Project Brain entrypoint'
Assert-True ($packet -match 'README.md \(over .* optional-base cap\)') 'prompt packet must report the oversized root README instead of selecting it'
$packetSelectedBlock = (($packet -split '## Selected files',2)[1] -split '## Skipped duplicate files',2)[0]
$packetFriendCopies = @($packetSelectedBlock -split "`r?`n" | Where-Object { $_ -match 'src\\friends(?:-copy)?\.ts' })
Assert-True ($packetFriendCopies.Count -eq 1) 'prompt packet must select only one copy of identical source content'
Assert-True ($packet -match 'duplicates src\\friends(?:-copy)?\.ts') 'prompt packet must report which duplicate source file was skipped'
$sessionContext = Get-Content -LiteralPath (Join-Path $ResolvedFixture '.ai\context\session-context.md') -Raw
Assert-True ($sessionContext.IndexOf('docs\project-brain\README.md') -lt $sessionContext.IndexOf('README.md when task-relevant')) 'session context must route Project Brain before the optional root README'

$originalDisableRg = $env:ADOS_DISABLE_RG
$env:ADOS_DISABLE_RG = '1'
try {
    & $Ados analyze -ProjectPath $ResolvedFixture -Task 'Find sendFriendRequest without ripgrep' -MaxFiles 100 -MaxCommits 20
}
finally { $env:ADOS_DISABLE_RG = $originalDisableRg }
$fallbackPacket = Get-Content -LiteralPath (Join-Path $ResolvedFixture '.ai\context\prompt-packet.generated.md') -Raw
Assert-True ($fallbackPacket -match 'src\\friends(?:-copy)?\.ts') 'native PowerShell fallback must find task-relevant files without rg'

& $Operations adapter -ProjectPath $ResolvedFixture
$adapter = Read-Json '.ai\context\project-adapter.generated.json'
Assert-True ($adapter.protectedBoundaries -contains 'secrets') 'custom adapters must not remove global protected boundaries'
Assert-True ($adapter.protectedBoundaries -contains 'custom boundary') 'custom adapters must add their protected boundaries'
& $Operations checkpoint -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -Phase 'test'
Write-FixtureFile 'src\friends.ts' "export function sendFriendRequest(userId: string): string { return userId.trim(); }`r`n"
Push-Location $ResolvedFixture
try {
    & git add src\friends.ts
    & git commit -q -m 'test: committed change after checkpoint'
}
finally { Pop-Location }
$fakeValue = 'test-only-' + 'not-a-secret'
Write-FixtureFile 'src\secret-fixture.ts' "api_key = `"$fakeValue`"`r`n"
Push-Location $ResolvedFixture
try { & git add src\secret-fixture.ts }
finally { Pop-Location }
& $Quality scope -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -AllowedScope @('src','tests')
Assert-True ((Read-Json '.ai\evidence\scope-guard.generated.json').status -eq 'PASS') 'scope guard must accept the allowed source change'

& $Quality verify -ProjectPath $ResolvedFixture -MaxLevel 2
Assert-True ((Read-Json '.ai\evidence\verification.generated.json').status -eq 'PASS') 'verification ladder must pass the fixture'
& $Quality evidence -ProjectPath $ResolvedFixture -RequireDiff $true
$secretGate = Read-Json '.ai\evidence\evidence-gate.generated.json'
$secretRequirement = @($secretGate.requirements | Where-Object { $_.name -eq 'no secret pattern in added diff' })[0]
Assert-True (-not $secretRequirement.passed) 'evidence gate must inspect staged changes even when checkpoint commits exist'
Push-Location $ResolvedFixture
try { & git restore --staged -- src\secret-fixture.ts }
finally { Pop-Location }
Remove-Item -LiteralPath (Join-Path $ResolvedFixture 'src\secret-fixture.ts') -Force
& $Quality verify -ProjectPath $ResolvedFixture -MaxLevel 2
& $Quality evidence -ProjectPath $ResolvedFixture -RequireDiff $true
Assert-True ((Read-Json '.ai\evidence\evidence-gate.generated.json').status -eq 'VERIFIED') 'evidence gate must verify an observed in-scope diff'
$prSummary = Read-Json '.ai\evidence\pr-evidence-summary.generated.json'
Assert-True ($prSummary.status -eq 'READY') 'fresh verified evidence must produce a ready PR summary'
Assert-True ($prSummary.evidenceCurrent) 'PR summary must match the current repository state'
$prMarkdown = Get-Content -LiteralPath (Join-Path $ResolvedFixture '.ai\evidence\pr-evidence-summary.generated.md') -Raw
Assert-True ($prMarkdown -match 'ADOS evidence summary') 'PR summary must create copy-ready Markdown'

Write-FixtureFile 'src\friends.ts' "export function sendFriendRequest(userId: string): string { return userId.trim().toLowerCase(); }`r`n"
& $Quality pr-summary -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior'
$staleSummary = Read-Json '.ai\evidence\pr-evidence-summary.generated.json'
Assert-True ($staleSummary.status -eq 'NOT_READY') 'repository changes after Evidence Gate must invalidate the PR summary'
Assert-True (-not $staleSummary.evidenceCurrent) 'stale evidence must be reported explicitly'
Push-Location $ResolvedFixture
try { & git restore -- src\friends.ts }
finally { Pop-Location }
& $Quality pr-summary -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior'
Assert-True ((Read-Json '.ai\evidence\pr-evidence-summary.generated.json').status -eq 'READY') 'restoring the verified repository state must restore summary readiness'

& $Memory regression-add -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -RegressionCommand 'git diff --check' -Files @('src\friends.ts')
& $Memory regression-search -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior'
Assert-True ((Read-Json '.ai\context\regression-context.generated.json').matches.Count -ge 1) 'regression memory must return the stored check'
& $Memory negative-add -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -Attempt 'Change database permissions' -Outcome 'Not the root cause' -Files @('src\friends.ts')
& $Memory decisions -ProjectPath $ResolvedFixture -Task 'Friend service request boundary'
$decisions = Read-Json '.ai\context\decision-context.generated.json'
Assert-True ($decisions.decisions.Count -ge 1) 'ADR memory must return the related decision'
Assert-True ($decisions.negativeMemory.Count -ge 1) 'decision context must include related negative memory'

$logPath = Join-Path $ResolvedFixture '.ai\test-work\failure.log'
$logLines = @('Running tests','Error: friend request failed','Expected: accepted','Received: rejected','at src/friends.ts:1:10')
for ($i = 0; $i -lt 20; $i++) { $logLines += 'retry failed' }
Write-FixtureFile '.ai\test-work\failure.log' ($logLines -join "`r`n")
& $Quality compress -ProjectPath $ResolvedFixture -LogPath $logPath
& $Quality fingerprint -ProjectPath $ResolvedFixture -LogPath $logPath -Task 'Fix sendFriendRequest behavior'
Assert-True ((Read-Json '.ai\context\compressed-log.generated.json').repeatedLinesSuppressed -ge 19) 'log compressor must suppress repeated lines'
Assert-True ((Read-Json '.ai\memory\error-fingerprints.json').entries.Count -ge 1) 'fingerprint memory must store an error signature'

& $Operations queue-add -ProjectPath $ResolvedFixture -Task 'Review friend regression evidence' -Priority high
& $Operations queue-next -ProjectPath $ResolvedFixture
Assert-True ((Read-Json '.ai\queue\next.generated.json').next.status -eq 'pending') 'queue engine must return the pending task'
& $Operations benchmark -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -MaxFiles 100
$benchmark = Read-Json '.ai\analytics\ab-benchmark.generated.json'
Assert-True ($benchmark.incremental.secondUpdated -eq 0) 'benchmark second index pass must be incremental'
Assert-True ([string]$benchmark.note -match 'no model API') 'benchmark must preserve the zero-paid-API boundary'
Assert-True ([string]$benchmark.head -eq (Read-Json '.ai\index\hash-index.generated.json').head) 'benchmark must bind metrics to the current HEAD'

& $Operations resume -ProjectPath $ResolvedFixture
Assert-True ((Read-Json '.ai\context\resume.generated.json').safeToResume) 'checkpoint must be resumable on the same branch'
& $Operations usage -ProjectPath $ResolvedFixture
Assert-True ((Read-Json '.ai\analytics\usage-summary.generated.json').eventCount -ge 1) 'usage analytics must contain local events'

& $Operations health -ProjectPath $ResolvedFixture -MaxFiles 100
$health = Read-Json '.ai\analytics\health.generated.json'
Assert-True ($health.status -eq 'HEALTHY') 'project health must pass project-owned thresholds for the clean fixture'
Assert-True ($health.thresholdSource -eq '.ados/health.json') 'project health must report the project-owned threshold source'
Assert-True ($health.historyCount -eq 1) 'first project health run must create one trend snapshot'
Assert-True ((Read-Json '.ai\analytics\night-audit.generated.json').metrics.sourceFiles -ge 1) 'night audit must expose deterministic JSON metrics'
& $Operations health -ProjectPath $ResolvedFixture -MaxFiles 100
$duplicateHealth = Read-Json '.ai\analytics\health.generated.json'
Assert-True ($duplicateHealth.historyCount -eq 1) 'identical consecutive health states must not grow history'
Assert-True (-not $duplicateHealth.snapshotRecorded) 'identical health state must report snapshot replacement'

Write-FixtureFile 'tests\friends.test.ts' "// TODO add a regression assertion`r`nimport { sendFriendRequest } from '../src/friends';`r`n"
& $Operations health -ProjectPath $ResolvedFixture -MaxFiles 100
$attentionHealth = Read-Json '.ai\analytics\health.generated.json'
Assert-True ($attentionHealth.status -eq 'ATTENTION') 'project health must flag a project-owned threshold breach'
Assert-True ($attentionHealth.historyCount -eq 2) 'changed health metrics must append a trend snapshot'
$todoTrend = @($attentionHealth.trend | Where-Object { $_.metric -eq 'todoMarkers' })[0]
Assert-True ($todoTrend.change -eq 'up') 'health trend must report an increased TODO count'
Push-Location $ResolvedFixture
try { & git restore -- tests\friends.test.ts }
finally { Pop-Location }

Write-FixtureFile '.ados\health.json' '{"schemaVersion":1,"thresholds":{"maxTodoMarkers":-1}}'
& $Operations health -ProjectPath $ResolvedFixture -MaxFiles 100
Assert-True ((Read-Json '.ai\analytics\health.generated.json').status -eq 'CONFIG_ERROR') 'invalid project health thresholds must fail closed'
Push-Location $ResolvedFixture
try { & git restore -- .ados\health.json }
finally { Pop-Location }

Push-Location $ResolvedFixture
try { $statusBeforeNight = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
& $Operations night -ProjectPath $ResolvedFixture -MaxFiles 100
Push-Location $ResolvedFixture
try { $statusAfterNight = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
Assert-True ($statusBeforeNight -eq $statusAfterNight) 'night mode must not change product-code Git status'
$nightSummary = Get-Content -LiteralPath (Join-Path $ResolvedFixture '.ai\analytics\night-mode.generated.md') -Raw
Assert-True ($nightSummary -match 'Project health: HEALTHY') 'night mode must include current project health'

Write-Host 'ADOS v0.3 smoke test: PASS'
