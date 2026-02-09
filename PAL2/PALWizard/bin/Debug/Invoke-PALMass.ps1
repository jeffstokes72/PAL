param(
    [Parameter(Mandatory=$true)]
    [string[]] $InputPaths,

    [Parameter()]
    [string] $OutputRoot = (Join-Path -Path (Get-Location).Path -ChildPath ("PAL_Mass_Reports_" + (Get-Date).ToString("yyyyMMdd_HHmmss"))),

    [Parameter()]
    [string] $PalScriptPath,

    [Parameter()]
    [string[]] $ThresholdFiles,

    [Parameter()]
    [int] $ThrottleLimit = 4,

    [Parameter()]
    [int] $PalThreads = 4,

    [Parameter()]
    [string] $AnalysisInterval = "AUTO",

    [Parameter()]
    [string] $StatusPath,

    [Parameter()]
    [switch] $OpenMasterReport
)

Set-StrictMode -Version 2

. (Join-Path -Path $PSScriptRoot -ChildPath "PALMass.ps1")

$result = Invoke-PalMass `
    -InputPaths $InputPaths `
    -OutputRoot $OutputRoot `
    -PalScriptPath $PalScriptPath `
    -ThresholdFiles $ThresholdFiles `
    -ThrottleLimit $ThrottleLimit `
    -PalThreads $PalThreads `
    -AnalysisInterval $AnalysisInterval `
    -StatusPath $StatusPath

Write-Host ""
Write-Host "OutputRoot  : $($result.OutputRoot)"
Write-Host "MasterReport: $($result.MasterReport)"
Write-Host "ResultsCsv  : $($result.ResultsCsv)"
Write-Host "ResultsJson : $($result.ResultsJson)"

if ($OpenMasterReport.IsPresent) {
    try { Start-Process -FilePath $result.MasterReport | Out-Null } catch { }
}

