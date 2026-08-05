[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('index','search','handoff')]
    [string]$Command,
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,
    [string]$Query = '',
    [int]$MaxCommits = 250,
    [int]$MaxResults = 12
)
$ErrorActionPreference = 'Stop'
function Resolve-RepoRoot { param([string]$Path) $resolved=(Resolve-Path $Path).Path; Push-Location $resolved; try { $root=(& git rev-parse --show-toplevel 2>$null|Out-String).Trim(); if(-not $root){throw "Not a Git repository: $resolved"}; return [IO.Path]::GetFullPath($root).TrimEnd('\','/') } finally { Pop-Location } }
function Ensure-Directory { param([string]$Path) if($Path){New-Item -ItemType Directory -Path $Path -Force|Out-Null} }
function Write-Utf8NoBom { param([string]$Path,[string]$Content) Ensure-Directory (Split-Path -Parent $Path); [IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false)) }
function Normalize-Terms { param([string]$Text) $stop=@('the','and','for','with','from','this','that','into','when','then','fix','fixed','update','updated','change','changed','add','added','remove','removed','error','issue','bug','task','project','code','file','files'); $parts=[regex]::Matches($Text.ToLowerInvariant(),'[a-z0-9_\-]{3,}')|ForEach-Object{$_.Value}; return @($parts|Where-Object{$stop -notcontains $_}|Sort-Object -Unique) }
function Get-MemoryPath { param([string]$Root) return Join-Path $Root '.ai\memory\repair-memory.json' }
function Invoke-Index { param([string]$Root,[int]$Limit) Push-Location $Root; try { $format='%H%x1f%ad%x1f%s%x1e'; $raw=(& git log -n $Limit --date=iso-strict --pretty=format:$format --name-only|Out-String); $records=New-Object Collections.Generic.List[object]; foreach($block in($raw -split [char]0x1e)){ $block=$block.Trim(); if(-not $block){continue}; $lines=@($block -split "`r?`n"); $header=$lines[0]-split [char]0x1f; if($header.Count-lt 3){continue}; $files=@($lines|Select-Object -Skip 1|Where-Object{$_ -and $_ -notmatch '^\s*$'}|Sort-Object -Unique); $subject=$header[2]; $terms=Normalize-Terms($subject+' '+($files-join' ')); $records.Add([pscustomobject]@{commit=$header[0];date=$header[1];subject=$subject;files=$files;terms=$terms}) }; $payload=[pscustomobject]@{generated=(Get-Date -Format o);repository=$Root;head=((& git rev-parse HEAD|Out-String).Trim());commitsIndexed=$records.Count;records=@($records)}; $path=Get-MemoryPath $Root; Write-Utf8NoBom $path ($payload|ConvertTo-Json -Depth 8); Write-Host "Indexed $($records.Count) commits into $path" } finally { Pop-Location } }
function Get-Score { param($Record,[string[]]$Terms) $score=0; foreach($term in $Terms){ if($Record.subject.ToLowerInvariant().Contains($term)){$score+=5}; foreach($recordTerm in $Record.terms){if($recordTerm -eq $term){$score+=2}}; foreach($file in $Record.files){if($file.ToLowerInvariant().Contains($term)){$score+=1}} }; return $score }
function Invoke-Search { param([string]$Root,[string]$Text,[int]$Limit) if(-not $Text){throw 'Query is required for search.'}; $path=Get-MemoryPath $Root; if(-not(Test-Path $path)){Invoke-Index $Root $MaxCommits}; $memory=Get-Content $path -Raw|ConvertFrom-Json; $terms=Normalize-Terms $Text; $results=foreach($record in $memory.records){$score=Get-Score $record $terms; if($score-gt 0){[pscustomobject]@{Score=$score;Commit=$record.commit.Substring(0,12);Date=$record.date;Subject=$record.subject;Files=(@($record.files)|Select-Object -First 5)-join', '}}}; $ranked=@($results|Sort-Object Score -Descending,Date -Descending|Select-Object -First $Limit); if($ranked.Count-eq 0){Write-Host 'No similar repairs found.';return}; $ranked|Format-Table -AutoSize; $lines=New-Object Collections.Generic.List[string]; $lines.Add('# Similar repair history');$lines.Add('');$lines.Add("Query: $Text");$lines.Add("Generated: $(Get-Date -Format o)");$lines.Add(''); foreach($item in $ranked){$lines.Add("## $($item.Commit) - $($item.Subject)");$lines.Add("- Score: $($item.Score)");$lines.Add("- Date: $($item.Date)");$lines.Add("- Files: $($item.Files)");$lines.Add('')}; Write-Utf8NoBom (Join-Path $Root '.ai\context\similar-repairs.generated.md') ($lines-join"`r`n") }
function Invoke-Handoff { param([string]$Root) Push-Location $Root; try { $branch=(& git branch --show-current|Out-String).Trim();$head=(& git rev-parse HEAD|Out-String).Trim();$status=(& git status --short|Out-String).TrimEnd();$diff=(& git diff --stat|Out-String).TrimEnd();$staged=(& git diff --cached --stat|Out-String).TrimEnd();$recent=(& git log -n 8 --pretty=format:'%h %ad %s' --date=short|Out-String).TrimEnd();$testsPath=Join-Path $Root '.ai\context\test-plan.generated.md';$tests=if(Test-Path $testsPath){Get-Content $testsPath -Raw}else{'No generated test plan.'};$content=@"
# Development handoff

Generated: $(Get-Date -Format o)
Branch: $branch
Commit: $head

## Working tree
```text
$(if($status){$status}else{'clean'})
```

## Unstaged diff summary
```text
$(if($diff){$diff}else{'none'})
```

## Staged diff summary
```text
$(if($staged){$staged}else{'none'})
```

## Recent commits
```text
$recent
```

## Focused checks
$tests

## Resume protocol
1. Read AGENTS.md and repository-specific rules.
2. Verify branch, HEAD, and working tree before edits.
3. Read current-state, decisions, session-context, and prompt packet when present.
4. Reproduce the issue or confirm the finish condition.
5. Continue through implementation, focused checks, repair, and final diff review.
6. Do not claim verification that was not observed.
"@; $path=Join-Path $Root '.ai\context\handoff.generated.md';Write-Utf8NoBom $path $content;Write-Host "Handoff written to $path" } finally { Pop-Location } }
$root=Resolve-RepoRoot $ProjectPath
switch($Command){'index'{Invoke-Index $root $MaxCommits};'search'{Invoke-Search $root $Query $MaxResults};'handoff'{Invoke-Handoff $root}}
