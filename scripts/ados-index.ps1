[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('index','symbols','tests','context','all')]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [string]$Task = '',
    [ValidateSet('auto','small','medium','large','protected')]
    [string]$ContextTier = 'auto',
    [int]$MaxFiles = 2000,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Common = Join-Path $PSScriptRoot 'ados-common.ps1'
. $Common

function Get-AdosLanguage {
    param([string]$Extension)
    $map = @{
        '.ts'='typescript'; '.tsx'='typescript'; '.js'='javascript'; '.jsx'='javascript';
        '.mjs'='javascript'; '.cjs'='javascript'; '.py'='python'; '.ps1'='powershell';
        '.psm1'='powershell'; '.rs'='rust'; '.go'='go'; '.java'='java'; '.kt'='kotlin';
        '.kts'='kotlin'; '.cs'='csharp'; '.sql'='sql'; '.md'='markdown'; '.json'='json';
        '.yaml'='yaml'; '.yml'='yaml'; '.toml'='toml'; '.txt'='text'
    }
    $key = $Extension.ToLowerInvariant()
    if ($map.ContainsKey($key)) { return $map[$key] }
    return 'unknown'
}

function Get-AdosImports {
    param([IO.FileInfo]$File)

    $values = @()
    foreach ($line in @(Get-Content -LiteralPath $File.FullName -ErrorAction SilentlyContinue)) {
        $value = $null
        if ($line -match '^\s*import\s+.*?from\s+["'']([^"'']+)["'']') { $value = $Matches[1] }
        elseif ($line -match '^\s*import\s+["'']([^"'']+)["'']') { $value = $Matches[1] }
        elseif ($line -match 'require\(["'']([^"'']+)["'']\)') { $value = $Matches[1] }
        elseif ($File.Extension -eq '.py' -and $line -match '^\s*from\s+([A-Za-z0-9_\.]+)\s+import') { $value = $Matches[1] }
        elseif ($File.Extension -eq '.py' -and $line -match '^\s*import\s+([A-Za-z0-9_\.]+)') { $value = $Matches[1] }
        elseif ($File.Extension -match '^\.ps(m)?1$' -and $line -match '^\s*(Import-Module|\.\s+)\s*["'']?([^\s"'']+)') { $value = $Matches[2] }
        if ($value -and $values -notcontains $value) { $values += [string]$value }
    }
    return @($values | Select-Object -First 80)
}

function Get-AdosSymbols {
    param([IO.FileInfo]$File, [string]$RelativePath)

    $symbols = @()
    $lines = @(Get-Content -LiteralPath $File.FullName -ErrorAction SilentlyContinue)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        $name = $null
        $kind = $null
        $exported = $false

        if ($File.Extension -match '^\.(ts|tsx|js|jsx|mjs|cjs)$') {
            if ($line -match '^\s*(export\s+)?(async\s+)?function\s+([A-Za-z_$][\w$]*)') { $name=$Matches[3]; $kind='function'; $exported=[bool]$Matches[1] }
            elseif ($line -match '^\s*(export\s+)?class\s+([A-Za-z_$][\w$]*)') { $name=$Matches[2]; $kind='class'; $exported=[bool]$Matches[1] }
            elseif ($line -match '^\s*(export\s+)?interface\s+([A-Za-z_$][\w$]*)') { $name=$Matches[2]; $kind='interface'; $exported=[bool]$Matches[1] }
            elseif ($line -match '^\s*(export\s+)?type\s+([A-Za-z_$][\w$]*)\s*=') { $name=$Matches[2]; $kind='type'; $exported=[bool]$Matches[1] }
            elseif ($line -match '^\s*(export\s+)?(const|let|var)\s+([A-Za-z_$][\w$]*)\s*=') { $name=$Matches[3]; $kind=$Matches[2]; $exported=[bool]$Matches[1] }
        }
        elseif ($File.Extension -eq '.py') {
            if ($line -match '^\s*def\s+([A-Za-z_][\w]*)\s*\(') { $name=$Matches[1]; $kind='function' }
            elseif ($line -match '^\s*class\s+([A-Za-z_][\w]*)') { $name=$Matches[1]; $kind='class' }
        }
        elseif ($File.Extension -match '^\.ps(m)?1$') {
            if ($line -match '^\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)') { $name=$Matches[1]; $kind='function' }
            elseif ($line -match '^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)') { $name=$Matches[1]; $kind='class' }
        }
        elseif ($File.Extension -eq '.go') {
            if ($line -match '^\s*func\s+(?:\([^\)]+\)\s+)?([A-Za-z_][\w]*)') { $name=$Matches[1]; $kind='function'; $exported=($name.Substring(0,1) -cmatch '[A-Z]') }
            elseif ($line -match '^\s*type\s+([A-Za-z_][\w]*)\s+(struct|interface)') { $name=$Matches[1]; $kind=$Matches[2] }
        }
        elseif ($File.Extension -match '^\.(rs|java|kt|kts|cs)$') {
            if ($line -match '\b(class|interface|enum|struct|trait)\s+([A-Za-z_][\w]*)') { $kind=$Matches[1]; $name=$Matches[2] }
            elseif ($line -match '\b(fn|fun)\s+([A-Za-z_][\w]*)\s*\(') { $kind='function'; $name=$Matches[2] }
        }

        if ($name) {
            $symbols += [pscustomobject]@{
                name = [string]$name
                kind = [string]$kind
                file = $RelativePath
                line = ($i + 1)
                exported = [bool]$exported
            }
        }
    }
    return @($symbols | Select-Object -First 500)
}

function Invoke-AdosIncrementalIndex {
    param([string]$Root, [int]$Limit, [bool]$Rebuild)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $indexPath = Join-Path $Root '.ai\index\hash-index.generated.json'
    $previous = Read-AdosJson $indexPath $null
    $previousMap = @{}
    if (-not $Rebuild -and $previous -and $previous.files) {
        foreach ($entry in @($previous.files)) { $previousMap[[string]$entry.path] = $entry }
    }

    $entries = @()
    $scanned = 0
    $reused = 0
    $updated = 0
    $totalBytes = 0
    $files = @(Get-AdosSourceFiles $Root $Limit -IncludeDocs)
    foreach ($file in $files) {
        $relative = Get-AdosRelativePath $Root $file.FullName
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $scanned++
        $totalBytes += $file.Length
        if ($previousMap.ContainsKey($relative) -and [string]$previousMap[$relative].hash -eq $hash) {
            $entries += $previousMap[$relative]
            $reused++
            continue
        }

        $imports = @(Get-AdosImports $file)
        $symbols = @(Get-AdosSymbols $file $relative)
        $entries += [pscustomobject]@{
            path = $relative
            hash = $hash
            bytes = [long]$file.Length
            language = Get-AdosLanguage $file.Extension
            imports = @($imports)
            symbols = @($symbols)
        }
        $updated++
    }

    $removed = 0
    foreach ($oldPath in $previousMap.Keys) {
        if (@($entries | Where-Object { [string]$_.path -eq $oldPath }).Count -eq 0) { $removed++ }
    }

    $timer.Stop()
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        repository = $Root
        head = Get-AdosHead $Root
        stats = [ordered]@{
            scanned = $scanned
            reused = $reused
            updated = $updated
            removed = $removed
            totalBytes = $totalBytes
            durationMs = $timer.ElapsedMilliseconds
        }
        files = @($entries | Sort-Object path)
    }
    Write-AdosJson $indexPath $payload 14
    Add-AdosUsageEvent $Root 'incremental-index' 'PASS' $timer.ElapsedMilliseconds $totalBytes 0 @{
        scanned=$scanned; reused=$reused; updated=$updated; removed=$removed
    }
    Write-Host "Incremental index written to $indexPath (reused $reused, updated $updated, removed $removed)"
    return $payload
}

function Invoke-AdosSymbolIndex {
    param([string]$Root, $HashIndex)

    if (-not $HashIndex) {
        $HashIndex = Read-AdosJson (Join-Path $Root '.ai\index\hash-index.generated.json') $null
    }
    if (-not $HashIndex) { $HashIndex = Invoke-AdosIncrementalIndex $Root $MaxFiles $false }

    $symbols = @()
    foreach ($entry in @($HashIndex.files)) { $symbols += @($entry.symbols) }
    $byName = @($symbols | Sort-Object name, file, line)
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        repository = $Root
        head = Get-AdosHead $Root
        symbolCount = $byName.Count
        symbols = @($byName)
    }
    $jsonPath = Join-Path $Root '.ai\index\symbol-index.generated.json'
    Write-AdosJson $jsonPath $payload 10

    $lines = @('# ADOS symbol index','',"Generated: $($payload.generated)","Symbols: $($payload.symbolCount)",'','## Symbols')
    foreach ($symbol in @($byName | Select-Object -First 500)) {
        $lines += "- ``$($symbol.name)`` ($($symbol.kind)) - ``$($symbol.file):$($symbol.line)``"
    }
    if ($byName.Count -eq 0) { $lines += '- none' }
    Write-AdosUtf8 (Join-Path $Root '.ai\index\symbol-index.generated.md') ($lines -join "`r`n")
    Write-Host "Symbol index written to $jsonPath ($($byName.Count) symbols)"
    return $payload
}

function Test-AdosTestFilePath {
    param([string]$Path)

    $normalized = ([string]$Path).Replace('/', '\')
    return [bool]($normalized -match '(?i)(^|[\\])(__tests__|tests?|specs?)([\\]|$)|\.(test|spec)\.[^\\]+$|(^|[\\])test_[^\\]+\.py$|_test\.(go|py)$')
}

function Get-AdosPackageRoot {
    param([string]$Root, [string]$RelativePath, $Cache)

    $directory = Split-Path -Parent (Join-Path $Root $RelativePath)
    if ($Cache -and $Cache.ContainsKey($directory)) { return [string]$Cache[$directory] }
    $visited = @()
    $markers = @('package.json','pyproject.toml','go.mod','Cargo.toml')
    while ($directory -and $directory.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        if ($Cache -and $Cache.ContainsKey($directory)) {
            $result = [string]$Cache[$directory]
            foreach ($path in $visited) { $Cache[$path] = $result }
            return $result
        }
        $visited += $directory
        foreach ($marker in $markers) {
            if (Test-Path -LiteralPath (Join-Path $directory $marker) -PathType Leaf) {
                $result = if ($directory.TrimEnd('\') -eq $Root.TrimEnd('\')) { '.' } else { Get-AdosRelativePath $Root $directory }
                if ($Cache) { foreach ($path in $visited) { $Cache[$path] = $result } }
                return $result
            }
        }
        if (@(Get-ChildItem -LiteralPath $directory -Filter '*.csproj' -File -ErrorAction SilentlyContinue).Count -gt 0) {
            $result = if ($directory.TrimEnd('\') -eq $Root.TrimEnd('\')) { '.' } else { Get-AdosRelativePath $Root $directory }
            if ($Cache) { foreach ($path in $visited) { $Cache[$path] = $result } }
            return $result
        }
        $parent = Split-Path -Parent $directory
        if (-not $parent -or $parent -eq $directory) { break }
        $directory = $parent
    }
    if ($Cache) { foreach ($path in $visited) { $Cache[$path] = '.' } }
    return '.'
}

function Get-AdosModulePathKey {
    param([string]$Path)

    $key = ([string]$Path).Replace('\','/').ToLowerInvariant()
    $key = $key -replace '\.(tsx?|jsx?|mjs|cjs|py|rs|go|java|kt|kts|cs|psm1|ps1)$',''
    return $key.TrimEnd('/')
}

function Add-AdosTestAssociation {
    param($Map, [string]$SourceFile, [string]$TestFile, [string]$PackageRoot, [string]$Reason, [string[]]$Symbols = @())

    $key = $SourceFile + '|' + $TestFile
    if (-not $Map.ContainsKey($key)) {
        $Map[$key] = [pscustomobject]@{
            sourceFile = $SourceFile
            testFile = $TestFile
            packageRoot = $PackageRoot
            reasons = @()
            symbols = @()
        }
    }
    $item = $Map[$key]
    $item.reasons = @($item.reasons + $Reason | Where-Object { $_ } | Sort-Object -Unique)
    $item.symbols = @($item.symbols + $Symbols | Where-Object { $_ } | Sort-Object -Unique | Select-Object -First 40)
}

function Invoke-AdosCompilerReferences {
    param([string]$Root)

    $resultPath = Join-Path $Root '.ai\index\compiler-references.generated.json'
    $rawPath = Join-Path $Root '.ai\index\compiler-references.raw.json'
    $helper = Join-Path $PSScriptRoot 'ados-ts-references.js'
    $currentHead = Get-AdosHead $Root
    $currentFingerprint = Get-AdosEvidenceFingerprint $Root
    $typescriptPackage = Join-Path $Root 'node_modules\typescript\package.json'
    $compilerMarker = if (Test-Path -LiteralPath $typescriptPackage -PathType Leaf) { (Get-FileHash -LiteralPath $typescriptPackage -Algorithm SHA256).Hash.ToLowerInvariant() } else { 'missing' }
    $previous = Read-AdosJson $resultPath $null
    if ($previous -and @($previous.PSObject.Properties.Name) -contains 'compilerMarker' -and [string]$previous.head -eq $currentHead -and [string]$previous.evidenceFingerprint -eq $currentFingerprint -and [string]$previous.compilerMarker -eq $compilerMarker) {
        Write-Host "Compiler references reused: $([string]$previous.status) ($(@($previous.references).Count) references)"
        return $previous
    }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node -or -not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        $payload = [ordered]@{ schemaVersion=1; generated=(Get-Date -Format o); status='SKIP'; reason='node or resolver helper unavailable'; head=$currentHead; evidenceFingerprint=$currentFingerprint; compilerMarker=$compilerMarker; references=@(); safety='No dependency installation or network call.' }
        Write-AdosJson $resultPath $payload 8
        return $payload
    }

    Remove-Item -LiteralPath $rawPath -Force -ErrorAction SilentlyContinue
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $helperArgument = '"' + $helper + '"'
    $rootArgument = '"' + $Root + '"'
    $outputArgument = '"' + $rawPath + '"'
    $process = Start-Process -FilePath $node.Source -ArgumentList @(
        $helperArgument,'--root',$rootArgument,'--output',$outputArgument,'--maxProjects','40','--maxFiles','4000','--maxSymbols','1200','--maxReferences','12000','--maxMilliseconds','30000'
    ) -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(35000)) {
        try { $process.Kill() } catch { }
        $timer.Stop()
        $payload = [ordered]@{ schemaVersion=1; generated=(Get-Date -Format o); status='PARTIAL'; reason='resolver exceeded the 35 second process limit'; head=$currentHead; evidenceFingerprint=$currentFingerprint; compilerMarker=$compilerMarker; resolver='typescript-language-service'; typescriptVersion=''; projectCount=0; filesAnalyzed=0; symbolsAnalyzed=0; referenceCount=0; durationMs=$timer.ElapsedMilliseconds; references=@(); safety='Read-only project-local TypeScript language service; process stopped at the configured limit.' }
        Write-AdosJson $resultPath $payload 8
        Remove-Item -LiteralPath $rawPath -Force -ErrorAction SilentlyContinue
        Write-Host 'Compiler references: PARTIAL (process time limit)'
        return $payload
    }
    $timer.Stop()
    $raw = Read-AdosJson $rawPath $null
    Remove-Item -LiteralPath $rawPath -Force -ErrorAction SilentlyContinue
    if (-not $raw) {
        $raw = [pscustomobject]@{ status='ERROR'; reason="resolver returned no readable output (exit $($process.ExitCode))"; references=@() }
    }
    $rawProperties = @($raw.PSObject.Properties.Name)
    $status = [string]$raw.status
    if (@('PASS','PARTIAL','SKIP','ERROR') -notcontains $status) { $status = 'ERROR' }
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        status = $status
        reason = [string]$raw.reason
        head = $currentHead
        evidenceFingerprint = $currentFingerprint
        compilerMarker = $compilerMarker
        resolver = $(if ($rawProperties -contains 'resolver' -and $raw.resolver) { [string]$raw.resolver } else { 'typescript-language-service' })
        typescriptVersion = $(if ($rawProperties -contains 'typescriptVersion' -and $raw.typescriptVersion) { [string]$raw.typescriptVersion } else { '' })
        projectCount = $(if ($rawProperties -contains 'projectCount' -and $raw.projectCount) { [int]$raw.projectCount } else { 0 })
        filesAnalyzed = $(if ($rawProperties -contains 'filesAnalyzed' -and $raw.filesAnalyzed) { [int]$raw.filesAnalyzed } else { 0 })
        symbolsAnalyzed = $(if ($rawProperties -contains 'symbolsAnalyzed' -and $raw.symbolsAnalyzed) { [int]$raw.symbolsAnalyzed } else { 0 })
        referenceCount = $(if ($rawProperties -contains 'references') { @($raw.references).Count } else { 0 })
        durationMs = $timer.ElapsedMilliseconds
        references = $(if ($rawProperties -contains 'references') { @($raw.references) } else { @() })
        safety = 'Read-only project-local TypeScript language service; no dependency installation, model, paid API, or network call.'
    }
    Write-AdosJson $resultPath $payload 10
    $lines = @('# ADOS compiler references','',"Status: $status","Reason: $($payload.reason)","TypeScript: $($payload.typescriptVersion)","Projects: $($payload.projectCount)","Files: $($payload.filesAnalyzed)","Symbols: $($payload.symbolsAnalyzed)","References: $($payload.referenceCount)","Duration ms: $($payload.durationMs)",'','| Symbol | Definition | Reference |','|---|---|---|')
    foreach ($item in @($payload.references | Select-Object -First 500)) { $lines += "| $($item.symbol) | $($item.definitionFile) | $($item.referenceFile):$($item.line) |" }
    if ($payload.referenceCount -eq 0) { $lines += '| none | none | none |' }
    if ($payload.referenceCount -gt 500) { $lines += "| ... | ... | $($payload.referenceCount - 500) references omitted |" }
    $lines += @('','_Optional local compiler evidence. Lexical indexes remain the fallback._')
    Write-AdosUtf8 (Join-Path $Root '.ai\index\compiler-references.generated.md') ($lines -join "`r`n")
    Add-AdosUsageEvent $Root 'compiler-references' $status $timer.ElapsedMilliseconds 0 0 @{ projects=$payload.projectCount; files=$payload.filesAnalyzed; symbols=$payload.symbolsAnalyzed; references=$payload.referenceCount }
    Write-Host "Compiler references: $status ($($payload.referenceCount) references)"
    return $payload
}

function Invoke-AdosTestSymbolMap {
    param([string]$Root, $HashIndex, $SymbolIndex, $CompilerReferences)

    if (-not $HashIndex) { $HashIndex = Read-AdosJson (Join-Path $Root '.ai\index\hash-index.generated.json') $null }
    if (-not $HashIndex) { $HashIndex = Invoke-AdosIncrementalIndex $Root $MaxFiles $false }
    if (-not $SymbolIndex) { $SymbolIndex = Read-AdosJson (Join-Path $Root '.ai\index\symbol-index.generated.json') $null }
    if (-not $SymbolIndex) { $SymbolIndex = Invoke-AdosSymbolIndex $Root $HashIndex }
    if (-not $CompilerReferences) { $CompilerReferences = Invoke-AdosCompilerReferences $Root }

    $entries = @($HashIndex.files)
    $codeLanguages = @('typescript','javascript','python','powershell','rust','go','java','kotlin','csharp','sql')
    $codeEntries = @($entries | Where-Object { $codeLanguages -contains [string]$_.language })
    $tests = @($codeEntries | Where-Object { Test-AdosTestFilePath ([string]$_.path) })
    $sources = @($codeEntries | Where-Object { -not (Test-AdosTestFilePath ([string]$_.path)) })
    $packageByPath = @{}
    $packageRootCache = @{}
    foreach ($entry in $codeEntries) { $packageByPath[[string]$entry.path] = Get-AdosPackageRoot $Root ([string]$entry.path) $packageRootCache }

    $sourceByModule = @{}
    foreach ($source in $sources) {
        $path = [string]$source.path
        $key = Get-AdosModulePathKey $path
        foreach ($moduleKey in @($key, $(if ($key.EndsWith('/index')) { $key.Substring(0, $key.Length - 6) } else { $null }))) {
            if (-not $moduleKey) { continue }
            if (-not $sourceByModule.ContainsKey($moduleKey)) { $sourceByModule[$moduleKey] = @() }
            $sourceByModule[$moduleKey] = @($sourceByModule[$moduleKey] + $path | Sort-Object -Unique)
        }
    }

    $symbolOwners = @{}
    foreach ($symbol in @($SymbolIndex.symbols)) {
        if (Test-AdosTestFilePath ([string]$symbol.file)) { continue }
        $name = ([string]$symbol.name).ToLowerInvariant()
        if (-not $symbolOwners.ContainsKey($name)) { $symbolOwners[$name] = @() }
        $symbolOwners[$name] = @($symbolOwners[$name] + [string]$symbol.file | Sort-Object -Unique)
    }

    $associationMap = @{}
    if ($CompilerReferences -and @('PASS','PARTIAL') -contains [string]$CompilerReferences.status) {
        foreach ($reference in @($CompilerReferences.references)) {
            $sourcePath = [string]$reference.definitionFile
            $testPath = [string]$reference.referenceFile
            if (-not (Test-AdosTestFilePath $testPath)) { continue }
            if (-not $packageByPath.ContainsKey($sourcePath) -or -not $packageByPath.ContainsKey($testPath)) { continue }
            if ([string]$packageByPath[$sourcePath] -ne [string]$packageByPath[$testPath]) { continue }
            Add-AdosTestAssociation $associationMap $sourcePath $testPath ([string]$packageByPath[$testPath]) 'compiler reference' @([string]$reference.symbol)
        }
    }
    foreach ($test in $tests) {
        $testPath = [string]$test.path
        $testPackage = [string]$packageByPath[$testPath]
        $testDirectory = Split-Path -Parent (Join-Path $Root $testPath)
        foreach ($import in @($test.imports)) {
            if (-not ([string]$import).StartsWith('.')) { continue }
            try {
                $resolved = [IO.Path]::GetFullPath((Join-Path $testDirectory ([string]$import)))
                if (-not $resolved.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $resolvedRelative = Get-AdosRelativePath $Root $resolved
                $moduleKey = Get-AdosModulePathKey $resolvedRelative
                $moduleSources = @($sourceByModule[$moduleKey])
                $exactSources = @($moduleSources | Where-Object { ([string]$_).Replace('\','/').ToLowerInvariant() -eq $resolvedRelative.Replace('\','/').ToLowerInvariant() })
                $selectedSources = if ($exactSources.Count -eq 1) { $exactSources } elseif ($moduleSources.Count -eq 1) { $moduleSources } else { @() }
                foreach ($sourcePath in $selectedSources) {
                    Add-AdosTestAssociation $associationMap $sourcePath $testPath $testPackage 'relative import'
                }
            }
            catch { }
        }

        $content = Get-Content -LiteralPath (Join-Path $Root $testPath) -Raw -ErrorAction SilentlyContinue
        $tokens = @([regex]::Matches([string]$content, '[A-Za-z_$][A-Za-z0-9_$]*') | ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique | Select-Object -First 2000)
        foreach ($token in $tokens) {
            if (-not $symbolOwners.ContainsKey($token)) { continue }
            $owners = @($symbolOwners[$token] | Where-Object { [string]$packageByPath[[string]$_] -eq $testPackage })
            if ($owners.Count -eq 1) {
                Add-AdosTestAssociation $associationMap ([string]$owners[0]) $testPath $testPackage 'unique symbol reference' @($token)
            }
        }

        $testStem = [IO.Path]::GetFileNameWithoutExtension($testPath) -replace '(?i)\.(test|spec)$','' -replace '(?i)^test_','' -replace '(?i)_test$',''
        foreach ($source in $sources) {
            $sourcePath = [string]$source.path
            if ([string]$packageByPath[$sourcePath] -ne $testPackage) { continue }
            $sourceStem = [IO.Path]::GetFileNameWithoutExtension($sourcePath)
            if ($testStem -and $sourceStem -eq $testStem) {
                Add-AdosTestAssociation $associationMap $sourcePath $testPath $testPackage 'matching file stem'
            }
        }
    }

    $associations = @($associationMap.Values | ForEach-Object {
        $confidence = if (@($_.reasons) -contains 'compiler reference') { 'compiler' } elseif (@($_.reasons) -contains 'relative import') { 'high' } elseif (@($_.reasons) -contains 'unique symbol reference') { 'medium' } else { 'medium' }
        [pscustomobject]@{ sourceFile=$_.sourceFile; testFile=$_.testFile; packageRoot=$_.packageRoot; confidence=$confidence; reasons=@($_.reasons); symbols=@($_.symbols) }
    } | Sort-Object sourceFile, testFile | Select-Object -First 5000)
    $indexBasis = @($entries | Sort-Object path | ForEach-Object { ([string]$_.path) + '|' + ([string]$_.hash) }) -join "`n"
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        repository = $Root
        head = Get-AdosHead $Root
        evidenceFingerprint = Get-AdosEvidenceFingerprint $Root
        indexFingerprint = Get-AdosTextHash $indexBasis
        sourceFiles = $sources.Count
        testFiles = $tests.Count
        associationCount = $associations.Count
        compilerReferences = [ordered]@{ status=[string]$CompilerReferences.status; reason=[string]$CompilerReferences.reason; references=@($CompilerReferences.references).Count }
        associations = @($associations)
        safety = 'Deterministic lexical associations only; source and test configuration remain authoritative.'
    }
    $jsonPath = Join-Path $Root '.ai\index\test-symbol-map.generated.json'
    Write-AdosJson $jsonPath $payload 12
    $lines = @('# ADOS test-to-symbol map','',"Generated: $($payload.generated)","Source files: $($sources.Count)","Test files: $($tests.Count)","Associations: $($associations.Count)",'','| Source | Test | Package | Confidence | Evidence |','|---|---|---|---|---|')
    foreach ($item in @($associations | Select-Object -First 500)) {
        $lines += "| $($item.sourceFile) | $($item.testFile) | $($item.packageRoot) | $($item.confidence) | $((@($item.reasons) -join ', ')) |"
    }
    if ($associations.Count -eq 0) { $lines += '| none | none | - | - | - |' }
    if ($associations.Count -gt 500) { $lines += "| ... | $($associations.Count - 500) additional associations omitted | - | - | - |" }
    $lines += @('','_Lexical navigation aid. Test configuration and source code remain authoritative._')
    Write-AdosUtf8 (Join-Path $Root '.ai\index\test-symbol-map.generated.md') ($lines -join "`r`n")
    Add-AdosUsageEvent $Root 'test-symbol-map' 'PASS' 0 0 0 @{ sources=$sources.Count; tests=$tests.Count; associations=$associations.Count }
    Write-Host "Test-to-symbol map written to $jsonPath ($($associations.Count) associations)"
    return $payload
}

function Get-AdosContextTier {
    param([string]$TaskText, [string]$RequestedTier)

    if ($RequestedTier -ne 'auto') { return $RequestedTier }
    if ($TaskText -match '(?i)auth|security|rls|sql|migration|production|release|payment|broker|trading|financial|secret|credential|deploy|architecture|permission|encryption') { return 'protected' }
    if ($TaskText -match '(?i)architecture|refactor|cross.project|multi.project|new feature|integration|upgrade') { return 'large' }
    if ($TaskText -match '(?i)readme|documentation|wording|typo|comment|changelog|rename') { return 'small' }
    return 'medium'
}

function Get-AdosContextBudget {
    param([string]$Tier)
    $budgets = @{ small=30000; medium=90000; large=180000; protected=240000 }
    return [int]$budgets[$Tier]
}

function Get-AdosFileScore {
    param($Entry, [string[]]$Terms, [string[]]$Changed)

    $score = 0
    $path = ([string]$Entry.path).ToLowerInvariant()
    if ($Changed -contains [string]$Entry.path) { $score += 100 }
    foreach ($term in $Terms) {
        if ($path.Contains($term)) { $score += 20 }
        foreach ($symbol in @($Entry.symbols)) {
            if (([string]$symbol.name).ToLowerInvariant().Contains($term)) { $score += 16 }
        }
        foreach ($import in @($Entry.imports)) {
            if (([string]$import).ToLowerInvariant().Contains($term)) { $score += 6 }
        }
    }
    if ($score -gt 0 -and $path -match '(?i)(test|spec)') { $score += 2 }
    return $score
}

function Get-AdosContextEntrypoints {
    param([string]$Root)

    $entrypoints = @()
    $adapter = Read-AdosJson (Join-Path $Root '.ai\context\project-adapter.generated.json') $null
    if ($adapter) {
        $propertyNames = @($adapter.PSObject.Properties | ForEach-Object { $_.Name })
        if ($propertyNames -contains 'contextEntrypoints') { $entrypoints += @($adapter.contextEntrypoints) }
    }
    $custom = Read-AdosJson (Join-Path $Root '.ados\adapter.json') $null
    if ($custom) {
        $propertyNames = @($custom.PSObject.Properties | ForEach-Object { $_.Name })
        if ($propertyNames -contains 'contextEntrypoints') { $entrypoints += @($custom.contextEntrypoints) }
    }
    $projectBrain = @(
        'docs/project-brain/README.md',
        'docs/project-brain/CURRENT_FOCUS.md',
        'docs/project-brain/AGENT_ENTRYPOINTS.md'
    )
    if (Test-Path -LiteralPath (Join-Path $Root $projectBrain[0]) -PathType Leaf) { $entrypoints += $projectBrain }
    return @($entrypoints | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace('/', '\') } | Sort-Object -Unique)
}

function Get-AdosSelectionHash {
    param([string]$Path)

    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
    catch { return '' }
}

function Invoke-AdosElasticContext {
    param([string]$Root, [string]$TaskText, [string]$RequestedTier, $HashIndex, $SymbolIndex, $TestMap)

    if (-not $TaskText) { throw 'Task is required for elastic context.' }
    if (-not $HashIndex) { $HashIndex = Read-AdosJson (Join-Path $Root '.ai\index\hash-index.generated.json') $null }
    if (-not $HashIndex) { $HashIndex = Invoke-AdosIncrementalIndex $Root $MaxFiles $false }
    if (-not $SymbolIndex) { $SymbolIndex = Invoke-AdosSymbolIndex $Root $HashIndex }
    if (-not $TestMap) { $TestMap = Read-AdosJson (Join-Path $Root '.ai\index\test-symbol-map.generated.json') $null }
    if (-not $TestMap) { $TestMap = Invoke-AdosTestSymbolMap $Root $HashIndex $SymbolIndex }

    $tier = Get-AdosContextTier $TaskText $RequestedTier
    $budget = Get-AdosContextBudget $tier
    $terms = @(Get-AdosTaskTerms $TaskText)
    $changed = @(Get-AdosChangedFiles $Root)
    $entrypoints = @(Get-AdosContextEntrypoints $Root)
    $requiredBaseFiles = @('AGENTS.md') + $entrypoints
    $baseFiles = @(
        '.ai\context\current-state.md','.ai\context\decisions.md',
        '.ai\context\project-adapter.generated.md','.ai\context\decision-context.generated.md',
        '.ai\context\repo-map.generated.md','.ai\context\test-plan.generated.md'
    )
    $optionalBaseFiles = @('README.md')
    $maxOptionalBaseBytes = [long]($budget / 4)

    $selected = @()
    $skippedBaseFiles = @()
    $skippedDuplicateFiles = @()
    $selectedHashOwners = @{}
    $duplicateBytesAvoided = 0
    $used = 0
    foreach ($base in ($requiredBaseFiles + $baseFiles + $optionalBaseFiles)) {
        $full = Join-Path $Root $base
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $size = (Get-Item -LiteralPath $full).Length
            $isOptional = $optionalBaseFiles -contains $base
            if ($isOptional -and $size -gt $maxOptionalBaseBytes) {
                $skippedBaseFiles += [pscustomobject]@{ path=$base; bytes=[long]$size; reason="optional base file exceeds $maxOptionalBaseBytes byte cap" }
                continue
            }
            $hash = Get-AdosSelectionHash $full
            if ($hash -and $selectedHashOwners.ContainsKey($hash)) {
                $skippedDuplicateFiles += [pscustomobject]@{ path=$base; bytes=[long]$size; duplicateOf=[string]$selectedHashOwners[$hash] }
                $duplicateBytesAvoided += [long]$size
                continue
            }
            if (($used + $size) -le $budget) {
                $reason = if ($entrypoints -contains $base) { 'repository entrypoint' } else { 'base context' }
                $selected += [pscustomobject]@{ path=$base; bytes=[long]$size; score=1000; reason=$reason }
                $used += $size
                if ($hash) { $selectedHashOwners[$hash] = $base }
            }
        }
    }

    $baseScores = @{}
    foreach ($entry in @($HashIndex.files)) {
        $score = Get-AdosFileScore $entry $terms $changed
        $baseScores[[string]$entry.path] = $score
    }
    $testBoost = @{}
    foreach ($association in @($TestMap.associations)) {
        $sourcePath = [string]$association.sourceFile
        if (-not $baseScores.ContainsKey($sourcePath) -or [int]$baseScores[$sourcePath] -le 0) { continue }
        $testPath = [string]$association.testFile
        $boost = if ([string]$association.confidence -eq 'compiler') { 80 } elseif ([string]$association.confidence -eq 'high') { 60 } else { 35 }
        if (-not $testBoost.ContainsKey($testPath) -or [int]$testBoost[$testPath] -lt $boost) { $testBoost[$testPath] = $boost }
    }
    $ranked = @()
    foreach ($entry in @($HashIndex.files)) {
        $path = [string]$entry.path
        $score = [int]$baseScores[$path]
        if ($testBoost.ContainsKey($path)) { $score += [int]$testBoost[$path] }
        if ($score -gt 0) { $ranked += [pscustomobject]@{ entry=$entry; score=$score; associatedTest=$testBoost.ContainsKey($path) } }
    }
    $ranked = @($ranked | Sort-Object -Property @{Expression='score';Descending=$true}, @{Expression={$_.entry.path};Descending=$false})
    foreach ($candidate in $ranked) {
        $path = [string]$candidate.entry.path
        $size = [long]$candidate.entry.bytes
        if (@($selected | Where-Object { [string]$_.path -eq $path }).Count -gt 0) { continue }
        if (@($skippedBaseFiles | Where-Object { [string]$_.path -eq $path }).Count -gt 0) { continue }
        $full = Join-Path $Root $path
        $hash = Get-AdosSelectionHash $full
        if ($hash -and $selectedHashOwners.ContainsKey($hash)) {
            $skippedDuplicateFiles += [pscustomobject]@{ path=$path; bytes=$size; duplicateOf=[string]$selectedHashOwners[$hash] }
            $duplicateBytesAvoided += $size
            continue
        }
        if (($used + $size) -gt $budget) { continue }
        $reason = 'task term or symbol match'
        if ($changed -contains $path) { $reason = 'changed file' }
        elseif ([bool]$candidate.associatedTest) { $reason = 'associated focused test' }
        $selected += [pscustomobject]@{ path=$path; bytes=$size; score=$candidate.score; reason=$reason }
        $used += $size
        if ($hash) { $selectedHashOwners[$hash] = $path }
    }

    $totalBytes = [long]$HashIndex.stats.totalBytes
    $reduction = 0
    if ($totalBytes -gt 0) { $reduction = [math]::Round((1 - ($used / [double]$totalBytes)) * 100, 2) }
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        task = $TaskText
        taskId = Get-AdosTaskId $TaskText
        tier = $tier
        budgetBytes = $budget
        selectedBytes = $used
        repositorySourceBytes = $totalBytes
        estimatedReductionPercent = $reduction
        terms = @($terms)
        selectedFiles = @($selected)
        skippedBaseFiles = @($skippedBaseFiles)
        skippedDuplicateFiles = @($skippedDuplicateFiles)
        duplicateBytesAvoided = [long]$duplicateBytesAvoided
        associatedTestFiles = @($selected | Where-Object { [string]$_.reason -eq 'associated focused test' } | ForEach-Object { [string]$_.path })
    }
    $jsonPath = Join-Path $Root '.ai\context\elastic-context.generated.json'
    Write-AdosJson $jsonPath $payload 10
    $lines = @(
        '# ADOS elastic context','',"Generated: $($payload.generated)","Tier: $tier",
        "Budget bytes: $budget","Selected bytes: $used","Estimated source reduction: $reduction%",'',
        '## Task','',$TaskText,'','## Selected files'
    )
    foreach ($item in $selected) { $lines += "- ``$($item.path)`` - $($item.bytes) bytes - $($item.reason)" }
    if ($selected.Count -eq 0) { $lines += '- none' }
    $lines += @('','## Skipped duplicate files')
    foreach ($item in $skippedDuplicateFiles) { $lines += "- ``$($item.path)`` - $($item.bytes) bytes - duplicates ``$($item.duplicateOf)``" }
    if ($skippedDuplicateFiles.Count -eq 0) { $lines += '- none' }
    $lines += "Duplicate bytes avoided: $duplicateBytesAvoided"
    $lines += @('','## Skipped oversized base files')
    foreach ($item in $skippedBaseFiles) { $lines += "- ``$($item.path)`` - $($item.bytes) bytes - $($item.reason)" }
    if ($skippedBaseFiles.Count -eq 0) { $lines += '- none' }
    Write-AdosUtf8 (Join-Path $Root '.ai\context\elastic-context.generated.md') ($lines -join "`r`n")
    Add-AdosUsageEvent $Root 'elastic-context' 'PASS' 0 $totalBytes $used @{ tier=$tier; files=$selected.Count; reductionPercent=$reduction; duplicateFiles=$skippedDuplicateFiles.Count; duplicateBytesAvoided=$duplicateBytesAvoided }
    Write-Host "Elastic context written to $jsonPath ($tier, $used of $budget bytes)"
    return $payload
}

$root = Resolve-AdosRepoRoot $ProjectPath
Ensure-AdosLocalExclude $root
$hashIndex = $null
$symbolIndex = $null
$testMap = $null
$compilerReferences = $null
switch ($Command) {
    'index' { $null = Invoke-AdosIncrementalIndex $root $MaxFiles ([bool]$Force) }
    'symbols' {
        $hashIndex = Read-AdosJson (Join-Path $root '.ai\index\hash-index.generated.json') $null
        $null = Invoke-AdosSymbolIndex $root $hashIndex
    }
    'tests' {
        $hashIndex = Read-AdosJson (Join-Path $root '.ai\index\hash-index.generated.json') $null
        $symbolIndex = Read-AdosJson (Join-Path $root '.ai\index\symbol-index.generated.json') $null
        $compilerReferences = Invoke-AdosCompilerReferences $root
        $null = Invoke-AdosTestSymbolMap $root $hashIndex $symbolIndex $compilerReferences
    }
    'context' {
        $hashIndex = Read-AdosJson (Join-Path $root '.ai\index\hash-index.generated.json') $null
        $symbolIndex = Read-AdosJson (Join-Path $root '.ai\index\symbol-index.generated.json') $null
        $testMap = Read-AdosJson (Join-Path $root '.ai\index\test-symbol-map.generated.json') $null
        $null = Invoke-AdosElasticContext $root $Task $ContextTier $hashIndex $symbolIndex $testMap
    }
    'all' {
        $hashIndex = Invoke-AdosIncrementalIndex $root $MaxFiles ([bool]$Force)
        $symbolIndex = Invoke-AdosSymbolIndex $root $hashIndex
        $compilerReferences = Invoke-AdosCompilerReferences $root
        $testMap = Invoke-AdosTestSymbolMap $root $hashIndex $symbolIndex $compilerReferences
        if ($Task) { $null = Invoke-AdosElasticContext $root $Task $ContextTier $hashIndex $symbolIndex $testMap }
    }
}
