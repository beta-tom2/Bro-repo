param(
    [string]$ProjectPath = "",
    [switch]$Global,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$DevCoreRoot = Split-Path -Parent $PSScriptRoot

function Resolve-NpxCommand {
    $npxCmd = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if ($npxCmd) { return $npxCmd.Source }

    $npx = Get-Command npx -ErrorAction SilentlyContinue
    if ($npx) { return $npx.Source }

    throw "npx was not found. Install Node.js/npm or repair PATH before installing skills."
}

$NpxCommand = Resolve-NpxCommand
$Failures = New-Object Collections.Generic.List[object]

function Invoke-SkillInstall {
    param([string]$Source, [string]$Skill)

    $args = @("skills", "add", $Source, "--skill", $Skill, "-y")
    if ($Global) { $args += "-g" }

    $display = ('"' + $NpxCommand + '" ') + ($args -join " ")
    Write-Host "[skill] $Skill <= $Source"
    if ($DryRun) {
        Write-Host "  DRY RUN: $display"
        return
    }

    & $NpxCommand @args
    if ($LASTEXITCODE -ne 0) {
        $Failures.Add([pscustomobject]@{ Source=$Source; Skill=$Skill; ExitCode=$LASTEXITCODE })
        Write-Warning "Skill install failed: $Skill from $Source (exit code $LASTEXITCODE). Continuing with remaining approved skills."
    }
}

$approvedSkills = @(
    @{ Source = "https://github.com/beta-tom2/albert-devcore"; Skill = "albert-skill-router" },
    @{ Source = "https://github.com/beta-tom2/albert-devcore"; Skill = "albert-architecture-review" },
    @{ Source = "https://github.com/beta-tom2/albert-devcore"; Skill = "albert-design-director" },
    @{ Source = "https://github.com/vercel-labs/skills"; Skill = "find-skills" },

    @{ Source = "https://github.com/anthropics/skills"; Skill = "frontend-design" },
    @{ Source = "https://github.com/pbakaus/impeccable"; Skill = "impeccable" },
    @{ Source = "https://github.com/Leonxlnx/taste-skill"; Skill = "design-taste-frontend" },
    @{ Source = "https://github.com/emilkowalski/skills"; Skill = "emil-design-eng" },
    @{ Source = "https://github.com/emilkowalski/skills"; Skill = "animate" },
    @{ Source = "https://github.com/emilkowalski/skills"; Skill = "find-animation-opportunities" },
    @{ Source = "https://github.com/emilkowalski/skills"; Skill = "improve-animations" },
    @{ Source = "https://github.com/emilkowalski/skills"; Skill = "review-animations" },
    @{ Source = "https://github.com/emilkowalski/skills"; Skill = "apple-design" },

    @{ Source = "https://github.com/expo/skills"; Skill = "expo-native-ui" },
    @{ Source = "https://github.com/expo/skills"; Skill = "expo-data-fetching" },
    @{ Source = "https://github.com/expo/skills"; Skill = "expo-upgrade" },
    @{ Source = "https://github.com/vercel-labs/agent-skills"; Skill = "vercel-react-native-skills" },
    @{ Source = "https://github.com/supabase/agent-skills"; Skill = "supabase" },
    @{ Source = "https://github.com/supabase/agent-skills"; Skill = "supabase-postgres-best-practices" },
    @{ Source = "https://github.com/obra/superpowers"; Skill = "systematic-debugging" },
    @{ Source = "https://github.com/obra/superpowers"; Skill = "verification-before-completion" },
    @{ Source = "https://github.com/mattpocock/skills"; Skill = "tdd" },
    @{ Source = "https://github.com/mattpocock/skills"; Skill = "codebase-design" },
    @{ Source = "https://github.com/mattpocock/skills"; Skill = "domain-modeling" },
    @{ Source = "https://github.com/mattpocock/skills"; Skill = "grilling" },
    @{ Source = "https://github.com/mattpocock/skills"; Skill = "improve-codebase-architecture" }
)

foreach ($entry in $approvedSkills) {
    Invoke-SkillInstall -Source $entry.Source -Skill $entry.Skill
}

if ($ProjectPath) {
    $resolvedProject = (Resolve-Path $ProjectPath).Path
    foreach ($localSkill in @("albert-skill-router", "albert-architecture-review", "albert-design-director")) {
        $skillSource = Join-Path $DevCoreRoot ("skills\\" + $localSkill)
        $skillTarget = Join-Path $resolvedProject (".agents\\skills\\" + $localSkill)
        Write-Host "[project-skill] $skillTarget"
        if (-not $DryRun) {
            New-Item -ItemType Directory -Force -Path $skillTarget | Out-Null
            Copy-Item -Path (Join-Path $skillSource "*") -Destination $skillTarget -Recurse -Force
        }
    }
}

Write-Host "Albert Dev Skills installation plan completed."
Write-Host "Policy remains selective: installed does not mean always invoked."
if (-not $DryRun -and $Failures.Count -gt 0) {
    Write-Warning ("{0} skill installation(s) failed. Review the summary below:" -f $Failures.Count)
    foreach ($failure in $Failures) {
        Write-Host ("  - {0} <= {1} (exit {2})" -f $failure.Skill,$failure.Source,$failure.ExitCode)
    }
    exit 2
}
