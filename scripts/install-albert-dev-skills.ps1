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
        throw "Skill install failed: $Skill from $Source (exit code $LASTEXITCODE)"
    }
}

$approvedSkills = @(
    @{ Source = "https://github.com/beta-tom2/albert-devcore"; Skill = "albert-skill-router" },
    @{ Source = "https://github.com/beta-tom2/albert-devcore"; Skill = "albert-architecture-review" },
    @{ Source = "https://github.com/vercel-labs/skills"; Skill = "find-skills" },
    @{ Source = "https://github.com/anthropics/skills"; Skill = "frontend-design" },
    @{ Source = "https://github.com/expo/skills"; Skill = "building-native-ui" },
    @{ Source = "https://github.com/expo/skills"; Skill = "native-data-fetching" },
    @{ Source = "https://github.com/expo/skills"; Skill = "upgrading-expo" },
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
    foreach ($localSkill in @("albert-skill-router", "albert-architecture-review")) {
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
