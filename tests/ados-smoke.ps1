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

Write-FixtureFile 'README.md' "# ADOS smoke fixture`r`n"
Write-FixtureFile 'src\friends.ts' "export function sendFriendRequest(userId: string): string { return userId; }`r`n"
Write-FixtureFile 'tests\friends.test.ts' "import { sendFriendRequest } from '../src/friends';`r`n"
Write-FixtureFile 'docs\adr\ADR-0001-friend-service.md' "# ADR-0001 Friend service boundary`r`n`r`nStatus: accepted`r`n`r`nFriend requests remain in the friend service.`r`n"
Write-FixtureFile '.ados\adapter.json' '{"name":"smoke-custom","protectedBoundaries":["custom boundary"]}'

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
Assert-True ((Read-Json '.ai\context\elastic-context.generated.json').selectedFiles.Count -ge 1) 'elastic context must select files'

& $Index index -ProjectPath $ResolvedFixture -MaxFiles 100
$second = Read-Json '.ai\index\hash-index.generated.json'
Assert-True ($second.stats.updated -eq 0) 'second index pass must not reanalyze unchanged files'
Assert-True ($second.stats.reused -eq $second.stats.scanned) 'second index pass must reuse every scanned file'

Push-Location $ResolvedFixture
try { $statusBeforeStart = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
& $Ados start -ProjectPath $ResolvedFixture -Task 'Prepare friend request review' -MaxFiles 100 -MaxCommits 20
Push-Location $ResolvedFixture
try { $statusAfterStart = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
Assert-True ($statusBeforeStart -eq $statusAfterStart) 'ADOS start must keep generated context out of product Git status'

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

& $Operations resume -ProjectPath $ResolvedFixture
Assert-True ((Read-Json '.ai\context\resume.generated.json').safeToResume) 'checkpoint must be resumable on the same branch'
& $Operations usage -ProjectPath $ResolvedFixture
Assert-True ((Read-Json '.ai\analytics\usage-summary.generated.json').eventCount -ge 1) 'usage analytics must contain local events'

Push-Location $ResolvedFixture
try { $statusBeforeNight = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
& $Operations night -ProjectPath $ResolvedFixture -MaxFiles 100
Push-Location $ResolvedFixture
try { $statusAfterNight = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
Assert-True ($statusBeforeNight -eq $statusAfterNight) 'night mode must not change product-code Git status'

Write-Host 'ADOS v0.3 smoke test: PASS'
