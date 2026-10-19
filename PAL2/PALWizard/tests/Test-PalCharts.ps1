# Exercises the SVG chart writer and the log-conversion argument fix.
# Run from any directory: pwsh -File PAL2/PALWizard/tests/Test-PalCharts.ps1

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$wizardDir = Split-Path -Parent $PSScriptRoot
$scriptDir = Join-Path $wizardDir 'Scripts'
. (Join-Path $scriptDir 'PAL.ps1') -ClearLog $false

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True
{
    param([bool]$Condition, [string]$Message)
    if (-not $Condition)
    {
        [void]$script:failures.Add($Message)
        Write-Host "FAIL $Message"
    }
    else
    {
        Write-Host "OK   $Message"
    }
}

$single = MakeNumeric -Values 12.5
Assert-True ($single -is [double[]]) 'one numeric value stays an array'
Assert-True ($single.Length -eq 1) 'one numeric value has length 1'
Assert-True ($single.GetUpperBound(0) -eq 0) 'one numeric value has GetUpperBound 0'

$mixed = MakeNumeric -Values @('1', '-', $null, '2.5', 'nope')
Assert-True ($mixed.Length -eq 2) 'non-numeric samples are dropped'
Assert-True ($mixed[1] -eq 2.5) 'second numeric sample is kept'

$clamped = ReduceArrayValuesToMax -aValues @(1, 5, 9) -ChartMaxLimit 4
Assert-True ($clamped.Length -eq 3) 'clamped series keeps every sample'
Assert-True ($clamped[2] -eq 4) 'values above the chart limit are clamped'

$oneClamp = ReduceArrayValuesToMax -aValues 9 -ChartMaxLimit 4
Assert-True ($oneClamp.Length -eq 1 -and $oneClamp[0] -eq 4) 'a single sample can be clamped'

$relogArgs = Format-RelogArguments -InputPaths @('C:\Logs\a file.blg', 'C:\Logs\b file.blg') -OutputPath 'C:\Temp\out file.csv' -BeginTime $null -EndTime $null
$relogCommand = 'relog.exe ' + (ConvertTo-WindowsProcessArguments -ArgumentList $relogArgs)
$expected = 'relog.exe "C:\Logs\a file.blg" "C:\Logs\b file.blg" -f csv -o "C:\Temp\out file.csv" -y'
Assert-True ($relogCommand -eq $expected) "multi-file relog command is quoted per path: $relogCommand"
Assert-True ($relogCommand -notlike '*""*') 'multi-file relog command has no doubled quotes'

$ranged = Format-RelogArguments -InputPaths @('C:\one.blg') -OutputPath 'C:\out.csv' -BeginTime '1/1/2024 1:00:00 AM' -EndTime '1/1/2024 2:00:00 AM'
$rangedCommand = 'relog.exe ' + (ConvertTo-WindowsProcessArguments -ArgumentList $ranged)
Assert-True ($rangedCommand -eq 'relog.exe C:\one.blg -f csv -o C:\out.csv -y -b "1/1/2024 1:00:00 AM" -e "1/1/2024 2:00:00 AM"') "time range is passed to relog: $rangedCommand"

$sampleDir = Join-Path ([System.IO.Path]::GetTempPath()) 'pal-chart-sample'
if (Test-Path $sampleDir) { Remove-Item $sampleDir -Recurse -Force }
New-Item -Path $sampleDir -ItemType Directory | Out-Null
$global:ChartSettings = New-Object psobject
Add-Member -InputObject $global:ChartSettings -NotePropertyName XInterval -NotePropertyValue 6
Add-Member -InputObject $global:ChartSettings -NotePropertyName XIntervalMax -NotePropertyValue 8
$script:CHART_LINE_THICKNESS = 2.5

$start = Get-Date '2024-06-01T08:00:00'
$times = @()
$sql = @()
$w3wp = @()
$lsass = @()
$warnMin = @()
$warnMax = @()
$critMin = @()
$critMax = @()
for ($i = 0; $i -lt 72; $i++)
{
    $times += $start.AddMinutes(5 * $i)
    $sql += [math]::Round(35 + (18 * [math]::Sin($i / 6.0)) + ($(if ($i -gt 40 -and $i -lt 55) { 45 } else { 0 })), 2)
    if ($i -ge 20 -and $i -le 24) { $w3wp += '-' }
    else { $w3wp += [math]::Round(22 + (12 * [math]::Sin($i / 5.0)) + ($(if ($i -gt 50) { 30 } else { 0 })), 2) }
    $lsass += [math]::Round(8 + (4 * [math]::Sin($i / 8.0)), 2)
    $warnMin += 70
    $warnMax += 85
    $critMin += 85
    $critMax += 100
}

$series = New-Object System.Collections.ArrayList
$values = @{
    'SQL01 / sqlservr' = $sql
    'SQL01 / w3wp' = $w3wp
    'SQL01 / lsass' = $lsass
}
ConvertCounterArraysToSeriesHashTable -alSeries $series -aDateTimes $times -htOfCounterValues $values -IsThresholdsEnabled $true -dWarningMin $warnMin -dWarningMax $warnMax -dCriticalMin $critMin -dCriticalMax $critMax

$chartPath = Join-Path $sampleDir 'Processor_Time0.svg'
$path = Write-PalChart -ChartTitle '\Processor(_Total)\% Processor Time' -SaveFilePath $chartPath -SeriesObjects $series
Assert-True (Test-Path $path) 'chart file is written'
[xml]$svg = Get-Content -Path $path -Raw
Assert-True ($null -ne $svg.svg) 'chart file is well-formed SVG'
$xmlText = Get-Content -Path $path -Raw
Assert-True ($xmlText.Contains('Warning')) 'warning band is labeled'
Assert-True ($xmlText.Contains('Critical')) 'critical band is labeled'
Assert-True ($xmlText.Contains('<polygon ')) 'threshold band is a filled polygon'
Assert-True (([regex]::Matches($xmlText, '<polyline ')).Count -ge 3) 'a gap in samples splits a line instead of connecting across it'
Assert-True ($xmlText.Contains('sqlservr')) 'counter instance name is in the legend'

$many = New-Object System.Collections.ArrayList
$thresholds = New-Object System.Collections.ArrayList
[void]$thresholds.Add($series[0])
for ($n = 0; $n -lt 3; $n++)
{
    [void]$many.Add((New-PalChartSeries -Name "instance $n" -ChartType 'Line' -Color '#0072B2' -XValues $times -YValues $sql -Y2Values @()))
}
$created = @(CreatePalCharts -ArrayListOfCounterSeries $many -ArrayListOfThresholdSeries $thresholds -MaxNumberOfItemsInChart 2 -OutputDirectoryPath ($sampleDir + [IO.Path]::DirectorySeparatorChar) -ImageFileName 'split' -ChartTitle 'Split instances')
Assert-True ($created.Count -eq 2) "twelve-instance cap splits charts (got $($created.Count))"

$htmlPath = Join-Path $sampleDir 'report.html'
@"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>PAL chart sample</title>
<style>body{font-family:Segoe UI,Tahoma,sans-serif;margin:24px;background:#f3f5f8;color:#1c2430}h1{font-size:22px}p{max-width:960px}</style>
</head>
<body>
<h1>PAL chart sample</h1>
<p>Process CPU crosses the warning band and then the critical band. w3wp has a short gap, drawn as a broken line. The amber band is warning and the red band is critical.</p>
<img src="Processor_Time0.svg" alt="Processor time chart" style="max-width:100%;height:auto;border:1px solid #d5dbe3;background:#fff">
</body>
</html>
"@ | Set-Content -Path $htmlPath -Encoding UTF8

if ($failures.Count -gt 0)
{
    Write-Host ($failures.Count.ToString() + ' failure(s)')
    exit 1
}
Write-Host "Sample report: $htmlPath"
exit 0
