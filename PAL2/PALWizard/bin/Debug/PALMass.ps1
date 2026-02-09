Set-StrictMode -Version 2

function Test-Ps7OrHigher {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7+ is required. Current: $($PSVersionTable.PSVersion). Install from https://github.com/PowerShell/PowerShell and re-run using pwsh."
    }
}

function Get-DefaultPalThresholdFiles {
    param(
        [Parameter(Mandatory=$true)][string] $PalRoot
    )

    $candidates = @(
        "QuickSystemOverview.xml", # requested: QuickSystemanalysis
        "SystemOverview.xml",      # requested: system analysis/reference
        "VMWare.xml"               # requested: VMWare
    )

    $resolved = @()
    foreach ($name in $candidates) {
        $p = Join-Path -Path $PalRoot -ChildPath $name
        if (Test-Path -LiteralPath $p) {
            $resolved += $p
        }
    }
    if ($resolved.Count -lt 1) {
        throw "Unable to locate default threshold XMLs in '$PalRoot'. Expected at least one of: $($candidates -join ', ')"
    }
    return $resolved
}

function Get-PalRootFromThisScript {
    # Scripts are intended to live next to PAL.ps1 (FlatFile layout).
    return $PSScriptRoot
}

function Resolve-PalScriptPath {
    param(
        [Parameter()][string] $PalScriptPath,
        [Parameter()][string] $PalRoot
    )
    if ([string]::IsNullOrWhiteSpace($PalRoot)) {
        $PalRoot = Get-PalRootFromThisScript
    }
    if ([string]::IsNullOrWhiteSpace($PalScriptPath)) {
        $PalScriptPath = Join-Path -Path $PalRoot -ChildPath "PAL.ps1"
    }
    if (-not (Test-Path -LiteralPath $PalScriptPath)) {
        throw "PAL.ps1 not found at '$PalScriptPath'. Provide -PalScriptPath or place this script next to PAL.ps1."
    }
    return (Resolve-Path -LiteralPath $PalScriptPath).Path
}

function Resolve-ThresholdFilePaths {
    param(
        [Parameter(Mandatory=$true)][string[]] $ThresholdFiles,
        [Parameter(Mandatory=$true)][string] $PalRoot
    )

    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($t in $ThresholdFiles) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $candidate = $t
        if (-not (Test-Path -LiteralPath $candidate)) {
            $candidate = Join-Path -Path $PalRoot -ChildPath $t
        }
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "Threshold XML not found: '$t' (checked literal path and '$PalRoot')"
        }
        $resolved.Add((Resolve-Path -LiteralPath $candidate).Path)
    }
    return $resolved.ToArray()
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory=$true)][string] $BasePath,
        [Parameter(Mandatory=$true)][string] $FullPath
    )
    $base = (Resolve-Path -LiteralPath $BasePath).Path
    if (Test-Path -LiteralPath $FullPath) {
        $full = (Resolve-Path -LiteralPath $FullPath).Path
    } else {
        $full = [IO.Path]::GetFullPath($FullPath)
    }

    $baseUri = New-Object System.Uri(($base.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar))
    $fullUri = New-Object System.Uri($full)
    $rel = $baseUri.MakeRelativeUri($fullUri).ToString()
    $rel = [Uri]::UnescapeDataString($rel)
    return ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
}

function New-SafePathSegment {
    param([Parameter(Mandatory=$true)][string] $Text)
    $s = $Text
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) {
        $s = $s.Replace($c, '_')
    }
    $s = $s.Trim()
    if ($s.Length -eq 0) { return "_" }
    return $s
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory=$true)][string] $Path,
        [Parameter(Mandatory=$true)] $Object
    )
    $json = $Object | ConvertTo-Json -Depth 8
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $json, [Text.Encoding]::UTF8)
}

function Get-PalAlertCountsFromReportXml {
    param([Parameter(Mandatory=$true)][string] $ReportXmlPath)
    if (-not (Test-Path -LiteralPath $ReportXmlPath)) {
        return [pscustomobject]@{ Warnings = 0; Criticals = 0; Total = 0 }
    }
    try {
        [xml] $doc = Get-Content -LiteralPath $ReportXmlPath -Encoding UTF8
        $alerts = $doc.SelectNodes('//ALERT')
        $warn = 0
        $crit = 0
        foreach ($a in @($alerts)) {
            if ($null -eq $a) { continue }
            $cond = $null
            if ($a.CONDITION) { $cond = [string]$a.CONDITION }
            elseif ($a.CONDITIONNAME) { $cond = [string]$a.CONDITIONNAME }
            if ($cond) {
                switch ($cond) {
                    "Warning" { $warn++ }
                    "Critical" { $crit++ }
                }
            }
        }
        return [pscustomobject]@{ Warnings = $warn; Criticals = $crit; Total = ($warn + $crit) }
    } catch {
        return [pscustomobject]@{ Warnings = 0; Criticals = 0; Total = 0 }
    }
}

function Invoke-PalSingleRun {
    param(
        [Parameter(Mandatory=$true)][string] $PalScriptPath,
        [Parameter(Mandatory=$true)][string] $LogPath,
        [Parameter(Mandatory=$true)][string] $ThresholdFilePath,
        [Parameter(Mandatory=$true)][string] $OutputDir,
        [Parameter()][int] $PalThreads = 4,
        [Parameter()][string] $AnalysisInterval = "AUTO"
    )

    if (-not (Test-Path -LiteralPath $LogPath)) { throw "BLG not found: $LogPath" }
    if (-not (Test-Path -LiteralPath $ThresholdFilePath)) { throw "Threshold XML not found: $ThresholdFilePath" }

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    $htmlName = "report.htm"
    $xmlName  = "report.xml"

    # Note: invoke PAL within this runspace. (Safe when called from separate runspaces/processes.)
    & $PalScriptPath `
        -Log $LogPath `
        -ThresholdFile $ThresholdFilePath `
        -AnalysisInterval $AnalysisInterval `
        -IsOutputHtml $true `
        -IsOutputXml $true `
        -HtmlOutputFileName $htmlName `
        -XmlOutputFileName $xmlName `
        -OutputDir $OutputDir `
        -AllCounterStats $true `
        -NumberOfThreads $PalThreads `
        -IsLowPriority $false `
        -DisplayReport $false `
        -ClearLog $false | Out-Null

    $htmlPath = Join-Path -Path $OutputDir -ChildPath $htmlName
    $xmlPath  = Join-Path -Path $OutputDir -ChildPath $xmlName

    return [pscustomobject]@{
        HtmlPath = $htmlPath
        XmlPath  = $xmlPath
    }
}

function Write-PalMasterHtmlReport {
    param(
        [Parameter(Mandatory=$true)][string] $OutputRoot,
        [Parameter(Mandatory=$true)][pscustomobject[]] $Results,
        [Parameter()][int] $HighlightTopN = 25
    )

    $indexPath = Join-Path -Path $OutputRoot -ChildPath "index.html"

    $sorted = @($Results | Sort-Object -Property Score, Criticals, Warnings -Descending)
    $top = @($sorted | Select-Object -First $HighlightTopN)
    $topSet = @{}
    foreach ($r in $top) { $topSet[$r.RunId] = $true }

    $css = @"
body { font: 12px/18px Segoe UI, Arial, sans-serif; margin: 18px; color: #111; }
h1,h2 { margin-bottom: 6px; }
.meta { color: #444; margin-bottom: 12px; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ddd; padding: 8px; vertical-align: top; }
th { background: #f3f3f3; text-align: left; }
tr.worst { background: #ffe0e0; }
.pill { display:inline-block; padding:2px 8px; border-radius: 12px; font-size: 12px; }
.pill.crit { background:#b00020; color:#fff; }
.pill.warn { background:#ff8c00; color:#111; }
.pill.ok { background:#e7f7ea; color:#1b5e20; border:1px solid #b7e0bf; }
code { background:#f7f7f7; padding: 1px 4px; border-radius: 4px; }
"@

    $rows = New-Object System.Text.StringBuilder
    foreach ($r in $sorted) {
        $isWorst = $topSet.ContainsKey($r.RunId)
        $rowClass = $(if ($isWorst) { "worst" } else { "" })
        $relLink = $r.ReportLink
        $critPill = if ($r.Criticals -gt 0) { "<span class='pill crit'>Critical: $($r.Criticals)</span>" } else { "<span class='pill ok'>Critical: 0</span>" }
        $warnPill = if ($r.Warnings -gt 0) { "<span class='pill warn'>Warning: $($r.Warnings)</span>" } else { "<span class='pill ok'>Warning: 0</span>" }
        [void]$rows.AppendLine("<tr class='$rowClass'>")
        [void]$rows.AppendLine("<td><code>$([System.Net.WebUtility]::HtmlEncode($r.RelativeBlgPath))</code></td>")
        [void]$rows.AppendLine("<td><code>$([System.Net.WebUtility]::HtmlEncode($r.ThresholdName))</code></td>")
        [void]$rows.AppendLine("<td>$critPill<br>$warnPill<br><b>Score:</b> $($r.Score)</td>")
        [void]$rows.AppendLine("<td><a href='$relLink'>Open report</a></td>")
        [void]$rows.AppendLine("</tr>")
    }

    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $totalRuns = $Results.Count
    $totalCrit = ($Results | Measure-Object -Property Criticals -Sum).Sum
    $totalWarn = ($Results | Measure-Object -Property Warnings -Sum).Sum

    $html = @"
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>PAL Mass Processing - Master Report</title>
  <style>$css</style>
</head>
<body>
  <h1>PAL Mass Processing - Master Report</h1>
  <div class="meta">
    Generated: <b>$now</b><br/>
    Runs: <b>$totalRuns</b> (Critical alerts: <b>$totalCrit</b>, Warning alerts: <b>$totalWarn</b>)<br/>
    Output root: <code>$([System.Net.WebUtility]::HtmlEncode($OutputRoot))</code>
  </div>

  <h2>All Reports (sorted by worst first)</h2>
  <table>
    <thead>
      <tr>
        <th>BLG</th>
        <th>Threshold XML</th>
        <th>Alerts</th>
        <th>Link</th>
      </tr>
    </thead>
    <tbody>
      $($rows.ToString())
    </tbody>
  </table>
</body>
</html>
"@

    [IO.File]::WriteAllText($indexPath, $html, [Text.Encoding]::UTF8)
    return $indexPath
}

function Invoke-PalMass {
    param(
        [Parameter(Mandatory=$true)][string[]] $InputPaths,
        [Parameter(Mandatory=$true)][string] $OutputRoot,
        [Parameter()][string] $PalScriptPath,
        [Parameter()][string[]] $ThresholdFiles,
        [Parameter()][int] $ThrottleLimit = 4,
        [Parameter()][int] $PalThreads = 4,
        [Parameter()][string] $AnalysisInterval = "AUTO",
        [Parameter()][string] $StatusPath
    )

    Test-Ps7OrHigher

    $palMassLibPath = Join-Path -Path $PSScriptRoot -ChildPath "PALMass.ps1"
    $palRoot = Split-Path -Parent (Resolve-PalScriptPath -PalScriptPath $PalScriptPath -PalRoot $PSScriptRoot)
    $PalScriptPath = Resolve-PalScriptPath -PalScriptPath $PalScriptPath -PalRoot $palRoot

    if (-not $ThresholdFiles -or $ThresholdFiles.Count -eq 0) {
        $ThresholdFiles = Get-DefaultPalThresholdFiles -PalRoot $palRoot
    } else {
        $ThresholdFiles = Resolve-ThresholdFilePaths -ThresholdFiles $ThresholdFiles -PalRoot $palRoot
    }

    $inputRoots = @()
    foreach ($p in $InputPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (Test-Path -LiteralPath $p)) { throw "Input path not found: $p" }
        $inputRoots += (Resolve-Path -LiteralPath $p).Path
    }
    if ($inputRoots.Count -eq 0) { throw "No valid -InputPaths provided." }

    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

    # Gather BLG files from selected roots.
    $blg = New-Object System.Collections.Generic.List[string]
    foreach ($root in $inputRoots) {
        Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.blg" -ErrorAction SilentlyContinue |
            ForEach-Object { $blg.Add($_.FullName) }
    }
    $blg = $blg | Sort-Object -Unique
    if ($blg.Count -eq 0) { throw "No .blg files found under: $($inputRoots -join ', ')" }

    $status = [ordered]@{
        startedUtc = (Get-Date).ToUniversalTime().ToString("o")
        completedUtc = $null
        inputRoots = $inputRoots
        outputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
        blgFilesTotal = $blg.Count
        blgFilesCompleted = 0
        runsCompleted = 0
        errors = 0
        lastUpdateUtc = (Get-Date).ToUniversalTime().ToString("o")
        current = $null
    }
    if ($StatusPath) { Write-JsonFile -Path $StatusPath -Object $status }

    # Process each BLG in parallel; within each BLG, run all selected threshold XMLs.
    $results = $blg | ForEach-Object -Parallel {
        $blgPath = $_

        . $using:palMassLibPath

        $palScript = $using:PalScriptPath
        $thresholds = $using:ThresholdFiles
        $outputRoot = $using:OutputRoot
        $analysisInterval = $using:AnalysisInterval
        $palThreads = $using:PalThreads
        $statusPath = $using:StatusPath
        $inputRoots = $using:inputRoots

        # Determine which input root this BLG belongs to (first match).
        $rootForRel = $null
        foreach ($r in $inputRoots) {
            $rr = $r.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            $prefix = $rr + [IO.Path]::DirectorySeparatorChar
            if ($blgPath.Equals($rr, [System.StringComparison]::OrdinalIgnoreCase) -or $blgPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rootForRel = $r
                break
            }
        }
        if (-not $rootForRel) { $rootForRel = $inputRoots[0] }

        $relative = Get-RelativePath -BasePath $rootForRel -FullPath $blgPath
        $relativeDir = Split-Path -Parent $relative
        if ([string]::IsNullOrWhiteSpace($relativeDir)) { $relativeDir = "" }

        $blgBase = [IO.Path]::GetFileNameWithoutExtension($blgPath)
        $blgBaseSafe = New-SafePathSegment -Text $blgBase

        $perBlgResults = New-Object System.Collections.Generic.List[object]

        foreach ($t in $thresholds) {
            $thresholdName = [IO.Path]::GetFileName($t)
            $thresholdBaseSafe = New-SafePathSegment -Text ([IO.Path]::GetFileNameWithoutExtension($thresholdName))

            $outDir = Join-Path -Path $outputRoot -ChildPath (Join-Path -Path $relativeDir -ChildPath (Join-Path -Path $blgBaseSafe -ChildPath $thresholdBaseSafe))

            $runId = [guid]::NewGuid().ToString()

            if ($statusPath) {
                try {
                    $st = Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json
                    $st.current = [ordered]@{ blg = $blgPath; threshold = $thresholdName; outputDir = $outDir; runId = $runId }
                    $st.lastUpdateUtc = (Get-Date).ToUniversalTime().ToString("o")
                    Write-JsonFile -Path $statusPath -Object $st
                } catch { }
            }

            $ok = $true
            $errorText = $null
            try {
                $runOut = Invoke-PalSingleRun -PalScriptPath $palScript -LogPath $blgPath -ThresholdFilePath $t -OutputDir $outDir -PalThreads $palThreads -AnalysisInterval $analysisInterval
            } catch {
                $ok = $false
                $errorText = $_.Exception.Message
                $runOut = [pscustomobject]@{ HtmlPath = (Join-Path $outDir "report.htm"); XmlPath = (Join-Path $outDir "report.xml") }
            }

            $counts = Get-PalAlertCountsFromReportXml -ReportXmlPath $runOut.XmlPath
            $score = ([int]$counts.Criticals * 10) + ([int]$counts.Warnings * 2) + (if (-not $ok) { 1000 } else { 0 })

            $reportLink = Get-RelativePath -BasePath $outputRoot -FullPath $runOut.HtmlPath
            $reportLink = $reportLink -replace '\\','/'

            $perBlgResults.Add([pscustomobject]@{
                RunId = $runId
                BlgPath = $blgPath
                RelativeBlgPath = $relative
                ThresholdPath = $t
                ThresholdName = $thresholdName
                OutputDir = $outDir
                ReportHtmlPath = $runOut.HtmlPath
                ReportXmlPath = $runOut.XmlPath
                Criticals = [int]$counts.Criticals
                Warnings = [int]$counts.Warnings
                Score = [int]$score
                Succeeded = $ok
                Error = $errorText
                ReportLink = $reportLink
            })
        }

        # Increment counters in status file (best-effort).
        if ($statusPath) {
            try {
                $st = Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json
                $st.blgFilesCompleted = [int]$st.blgFilesCompleted + 1
                $st.runsCompleted = [int]$st.runsCompleted + $perBlgResults.Count
                $st.errors = [int]$st.errors + (@($perBlgResults | Where-Object { -not $_.Succeeded }).Count)
                $st.lastUpdateUtc = (Get-Date).ToUniversalTime().ToString("o")
                Write-JsonFile -Path $statusPath -Object $st
            } catch { }
        }

        return $perBlgResults
    } -ThrottleLimit $ThrottleLimit

    $flat = @()
    foreach ($x in @($results)) {
        if ($x -is [System.Collections.IEnumerable]) { $flat += @($x) } else { $flat += $x }
    }

    $indexPath = Write-PalMasterHtmlReport -OutputRoot $OutputRoot -Results $flat
    $csvPath = Join-Path -Path $OutputRoot -ChildPath "results.csv"
    $jsonPath = Join-Path -Path $OutputRoot -ChildPath "results.json"

    $flat | Select-Object RelativeBlgPath, ThresholdName, Criticals, Warnings, Score, Succeeded, ReportHtmlPath, ReportXmlPath, Error |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    Write-JsonFile -Path $jsonPath -Object $flat

    if ($StatusPath) {
        try {
            $st = Get-Content -LiteralPath $StatusPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $st.completedUtc = (Get-Date).ToUniversalTime().ToString("o")
            $st.lastUpdateUtc = (Get-Date).ToUniversalTime().ToString("o")
            $st.masterReport = $indexPath
            Write-JsonFile -Path $StatusPath -Object $st
        } catch { }
    }

    return [pscustomobject]@{
        OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
        MasterReport = $indexPath
        ResultsCsv = $csvPath
        ResultsJson = $jsonPath
        Runs = $flat
    }
}

