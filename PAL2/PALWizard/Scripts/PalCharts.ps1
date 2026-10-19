# PalCharts.ps1
# SVG charts for PAL reports. No WinForms or GDI+ dependency.
# Dot-sourced by PAL.ps1. Safe to dot-source from tests.

Function ConvertTo-PalXmlText
{
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $text = $Value.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
    return $text
}

Function Format-SvgNumber
{
    param([double]$Value)
    return $Value.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

Function ConvertTo-PalDoubleArray
{
    # One pass per series. Missing or non-numeric samples become NaN so the
    # renderers can split lines at gaps without calling back into PowerShell per point.
    param($Values)
    $source = @($Values)
    $result = New-Object double[] $source.Count
    for ($i = 0; $i -lt $source.Count; $i++)
    {
        $value = $source[$i]
        $number = [double]::NaN
        if ($value -is [double]) { $number = $value }
        elseif ($value -is [int] -or $value -is [long] -or $value -is [decimal] -or $value -is [single]) { $number = [double]$value }
        elseif ($null -ne $value)
        {
            $parsed = 0.0
            if ([double]::TryParse([string]$value, [ref]$parsed)) { $number = $parsed }
        }
        if ([double]::IsInfinity($number)) { $number = [double]::NaN }
        $result[$i] = $number
    }
    return ,$result
}

Function Get-PalPlotIndexes
{
    # Returns the sample indexes worth drawing. Short series are drawn in full. Long
    # series are bucketed and only each bucket's min and max are kept, which preserves
    # spikes while capping SVG size and render time. A bucket with no numeric samples
    # contributes one NaN index so the line still breaks at a real gap.
    param([double[]]$Values, [int]$MaxPoints)
    $count = $Values.Length
    $indexes = New-Object System.Collections.Generic.List[int]
    if ($count -le $MaxPoints)
    {
        for ($i = 0; $i -lt $count; $i++) { [void]$indexes.Add($i) }
        return ,$indexes.ToArray()
    }

    $bucketSize = [int][math]::Ceiling($count / ($MaxPoints / 2.0))
    for ($start = 0; $start -lt $count; $start += $bucketSize)
    {
        $end = [math]::Min($start + $bucketSize, $count)
        $minIndex = -1
        $maxIndex = -1
        $gapIndex = -1
        for ($i = $start; $i -lt $end; $i++)
        {
            $v = $Values[$i]
            if ([double]::IsNaN($v)) { if ($gapIndex -lt 0) { $gapIndex = $i }; continue }
            if ($minIndex -lt 0 -or $v -lt $Values[$minIndex]) { $minIndex = $i }
            if ($maxIndex -lt 0 -or $v -gt $Values[$maxIndex]) { $maxIndex = $i }
        }
        if ($minIndex -lt 0)
        {
            [void]$indexes.Add($gapIndex)
        }
        elseif ($minIndex -eq $maxIndex)
        {
            [void]$indexes.Add($minIndex)
        }
        else
        {
            [void]$indexes.Add([math]::Min($minIndex, $maxIndex))
            [void]$indexes.Add([math]::Max($minIndex, $maxIndex))
        }
    }
    return ,$indexes.ToArray()
}

Function Get-PalChartPalette
{
    # Okabe-Ito, then a few extra dark colors. Chosen so lines stay distinct on white
    # and on top of the yellow/red threshold bands.
    return @(
        '#0072B2',
        '#D55E00',
        '#009E73',
        '#CC79A7',
        '#56B4E9',
        '#882255',
        '#44AA99',
        '#000000',
        '#E69F00',
        '#332288',
        '#117733',
        '#AA4499'
    )
}

Function Get-PalChartCulture
{
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    $pal = Get-Variable -Name oPal -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $pal -or $null -eq $pal.Value) { return $culture }
    $prop = $pal.Value.PSObject.Properties['Culture']
    if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
    return $culture
}

Function Format-PalTick
{
    param([double]$Value, [double]$Step, $Culture)
    $abs = [math]::Abs($Step)
    $format = '#,0.##'
    if ($abs -ge 1000 -and [math]::Abs($Value - [math]::Round($Value)) -lt 0.001) { $format = '#,0' }
    elseif ($abs -lt 0.001) { $format = '0.0000' }
    elseif ($abs -lt 0.01) { $format = '0.000' }
    elseif ($abs -lt 0.1) { $format = '0.00' }
    elseif ($abs -lt 1) { $format = '0.0' }
    elseif ($abs -ge 1 -and $abs -lt 1000) { $format = '#,0.##' }
    return $Value.ToString($format, $Culture)
}

Function Get-PalAxisScale
{
    param([double]$Min, [double]$Max)

    if ($Min -gt $Max)
    {
        $swap = $Min
        $Min = $Max
        $Max = $swap
    }
    if ($Min -eq $Max)
    {
        $pad = [math]::Abs($Min) * 0.1
        if ($pad -eq 0) { $pad = 1 }
        $Min = $Min - $pad
        $Max = $Max + $pad
    }

    $span = $Max - $Min
    $raw = $span / 5.0
    if ($raw -le 0) { $raw = 1 }
    $mag = [math]::Pow(10, [math]::Floor([math]::Log10($raw)))
    if ($mag -eq 0) { $mag = 1 }
    $norm = $raw / $mag
    $stepFactor = 10.0
    if ($norm -le 1) { $stepFactor = 1 }
    elseif ($norm -le 2) { $stepFactor = 2 }
    elseif ($norm -le 2.5) { $stepFactor = 2.5 }
    elseif ($norm -le 5) { $stepFactor = 5 }

    $step = $stepFactor * $mag
    $niceMin = [math]::Floor($Min / $step) * $step
    $niceMax = [math]::Ceiling($Max / $step) * $step
    if ($niceMax -le $niceMin) { $niceMax = $niceMin + $step }

    $ticks = New-Object System.Collections.Generic.List[double]
    $cursor = $niceMin
    $guard = 0
    while (($cursor -le ($niceMax + ($step * 0.001))) -and ($guard -lt 24))
    {
        [void]$ticks.Add([math]::Round($cursor, 10))
        $cursor += $step
        $guard++
    }

    $scale = New-Object pscustomobject
    Add-Member -InputObject $scale -MemberType NoteProperty -Name Min -Value $niceMin
    Add-Member -InputObject $scale -MemberType NoteProperty -Name Max -Value $niceMax
    Add-Member -InputObject $scale -MemberType NoteProperty -Name Step -Value $step
    Add-Member -InputObject $scale -MemberType NoteProperty -Name Ticks -Value $ticks.ToArray()
    return $scale
}

Function AddADashStyle
{
    param($Series, $DashStyleNumber)
    $styles = @('Solid','Dash','DashDot','Dot')
    $index = 0
    if ($null -ne $DashStyleNumber)
    {
        $index = [int]$DashStyleNumber % 4
        if ($index -lt 0) { $index = 0 }
    }
    if ($null -eq $Series.PSObject.Properties['DashStyle'])
    {
        Add-Member -InputObject $Series -MemberType NoteProperty -Name DashStyle -Value $styles[$index]
    }
    else
    {
        $Series.DashStyle = $styles[$index]
    }
    return $Series
}

Function ConvertTo-PalDashArray
{
    param([string]$DashStyle, [double]$Width)
    $scale = [math]::Max(1.0, $Width)
    switch ($DashStyle)
    {
        'Dash' { return (Format-SvgNumber (7 * $scale)) + ' ' + (Format-SvgNumber (4 * $scale)) }
        'DashDot' { return (Format-SvgNumber (7 * $scale)) + ' ' + (Format-SvgNumber (3 * $scale)) + ' ' + (Format-SvgNumber (1.5 * $scale)) + ' ' + (Format-SvgNumber (3 * $scale)) }
        'Dot' { return (Format-SvgNumber (1.4 * $scale)) + ' ' + (Format-SvgNumber (3 * $scale)) }
        default { return '' }
    }
}

Function New-PalChartSeries
{
    param(
        [string]$Name,
        [string]$ChartType,
        [string]$Color,
        $XValues,
        $YValues,
        $Y2Values
    )
    $series = New-Object pscustomobject
    Add-Member -InputObject $series -MemberType NoteProperty -Name Name -Value $Name
    Add-Member -InputObject $series -MemberType NoteProperty -Name ChartType -Value $ChartType
    Add-Member -InputObject $series -MemberType NoteProperty -Name Color -Value $Color
    Add-Member -InputObject $series -MemberType NoteProperty -Name DashStyle -Value 'Solid'
    Add-Member -InputObject $series -MemberType NoteProperty -Name BorderWidth -Value 2.5
    Add-Member -InputObject $series -MemberType NoteProperty -Name XValues -Value @($XValues)
    Add-Member -InputObject $series -MemberType NoteProperty -Name YValues -Value @($YValues)
    Add-Member -InputObject $series -MemberType NoteProperty -Name Y2Values -Value @($Y2Values)
    return $series
}

Function ConvertCounterArraysToSeriesHashTable
{
    param($alSeries, $aDateTimes, $htOfCounterValues, $IsThresholdsEnabled, $dWarningMin, $dWarningMax, $dCriticalMin, $dCriticalMax, $sBackGradientStyle='TopBottom')

    $times = @($aDateTimes)
    if ($IsThresholdsEnabled -eq $True)
    {
        if ($null -ne $dCriticalMin -or $null -ne $dCriticalMax)
        {
            [void]$alSeries.Add((New-PalChartSeries -Name 'Critical' -ChartType 'Range' -Color '#E45756' -XValues $times -YValues @($dCriticalMin) -Y2Values @($dCriticalMax)))
        }
        if ($null -ne $dWarningMin -or $null -ne $dWarningMax)
        {
            [void]$alSeries.Add((New-PalChartSeries -Name 'Warning' -ChartType 'Range' -Color '#F0C419' -XValues $times -YValues @($dWarningMin) -Y2Values @($dWarningMax)))
        }
    }

    $entries = @($htOfCounterValues.GetEnumerator() | Sort-Object Name)
    $palette = Get-PalChartPalette
    $lineThickness = 2.5
    $thicknessVar = Get-Variable -Name CHART_LINE_THICKNESS -ErrorAction SilentlyContinue
    if ($null -ne $thicknessVar -and $thicknessVar.Value -gt 0) { $lineThickness = [double]$thicknessVar.Value }

    for ($a = 0; $a -lt $entries.Count; $a++)
    {
        $values = @($entries[$a].Value)
        $xValues = New-Object System.Collections.Generic.List[object]
        $yValues = New-Object System.Collections.Generic.List[object]
        for ($b = 0; $b -lt $values.Count; $b++)
        {
            if ($b -lt $times.Count) { [void]$xValues.Add($times[$b]) }
            else { [void]$xValues.Add($null) }
            [void]$yValues.Add($values[$b])
        }
        $color = $palette[$a % $palette.Count]
        $series = New-PalChartSeries -Name ([string]$entries[$a].Name) -ChartType 'Line' -Color $color -XValues $xValues.ToArray() -YValues $yValues.ToArray() -Y2Values @()
        $series.BorderWidth = $lineThickness
        $series = AddADashStyle -Series $series -DashStyleNumber $a
        [void]$alSeries.Add($series)
    }
}

Function Get-PalPlotX
{
    param([int]$Index, [int]$Count, [double]$Left, [double]$Width)
    if ($Count -le 1) { return $Left + ($Width / 2.0) }
    return $Left + (($Index / [double]($Count - 1)) * $Width)
}

Function Get-PalPlotY
{
    param([double]$Value, [double]$Min, [double]$Max, [double]$Top, [double]$Height)
    $span = $Max - $Min
    if ($span -eq 0) { $span = 1 }
    $ratio = ($Value - $Min) / $span
    return $Top + ((1.0 - $ratio) * $Height)
}

Function New-PalPlotTransform
{
    # Precomputed factors so the per-point loops are plain arithmetic.
    param([int]$SampleCount, $Scale, [double]$Left, [double]$Top, [double]$PlotWidth, [double]$PlotHeight)
    $xStep = 0.0
    $xOffset = $Left
    if ($SampleCount -gt 1) { $xStep = $PlotWidth / [double]($SampleCount - 1) }
    else { $xOffset = $Left + ($PlotWidth / 2.0) }
    $span = $Scale.Max - $Scale.Min
    if ($span -eq 0) { $span = 1 }
    $transform = New-Object pscustomobject
    Add-Member -InputObject $transform -MemberType NoteProperty -Name XOffset -Value $xOffset
    Add-Member -InputObject $transform -MemberType NoteProperty -Name XStep -Value $xStep
    Add-Member -InputObject $transform -MemberType NoteProperty -Name YMax -Value ([double]$Scale.Max)
    Add-Member -InputObject $transform -MemberType NoteProperty -Name YFactor -Value ($PlotHeight / $span)
    Add-Member -InputObject $transform -MemberType NoteProperty -Name Top -Value $Top
    return $transform
}

Function Add-PalRangeGeometry
{
    param($Builder, $Series, [int]$SampleCount, $Scale, [double]$Left, [double]$Top, [double]$PlotWidth, [double]$PlotHeight, [int]$MaxPoints = 1600)

    $y1 = ConvertTo-PalDoubleArray $Series.YValues
    $y2 = ConvertTo-PalDoubleArray $Series.Y2Values
    $limit = [math]::Min([math]::Min($y1.Length, $y2.Length), $SampleCount)
    $indexes = Get-PalPlotIndexes -Values $y2 -MaxPoints $MaxPoints
    $t = New-PalPlotTransform -SampleCount $SampleCount -Scale $Scale -Left $Left -Top $Top -PlotWidth $PlotWidth -PlotHeight $PlotHeight
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $xOffset = [double]$t.XOffset; $xStep = [double]$t.XStep; $yMax = [double]$t.YMax; $yFactor = [double]$t.YFactor; $top = [double]$t.Top

    $highs = New-Object System.Collections.Generic.List[string]
    $lows = New-Object System.Collections.Generic.List[string]
    $polygons = New-Object System.Collections.Generic.List[string]
    $lines = New-Object System.Collections.Generic.List[string]

    for ($n = 0; $n -le $indexes.Length; $n++)
    {
        $hasPoint = $false
        if ($n -lt $indexes.Length)
        {
            $i = $indexes[$n]
            if ($i -lt $limit)
            {
                $low = $y1[$i]
                $high = $y2[$i]
                if (-not ([double]::IsNaN($low) -or [double]::IsNaN($high)))
                {
                    if ($high -lt $low) { $swap = $low; $low = $high; $high = $swap }
                    $x = ($xOffset + ($i * $xStep)).ToString('0.##', $inv)
                    [void]$highs.Add($x + ',' + ($top + (($yMax - $high) * $yFactor)).ToString('0.##', $inv))
                    [void]$lows.Add($x + ',' + ($top + (($yMax - $low) * $yFactor)).ToString('0.##', $inv))
                    $hasPoint = $true
                }
            }
        }
        if ((-not $hasPoint) -or ($n -eq $indexes.Length))
        {
            if ($highs.Count -ge 2)
            {
                $lows.Reverse()
                [void]$polygons.Add(($highs -join ' ') + ' ' + ($lows -join ' '))
            }
            elseif ($highs.Count -eq 1)
            {
                [void]$lines.Add($highs[0] + ' ' + $lows[0])
            }
            $highs.Clear()
            $lows.Clear()
        }
    }

    foreach ($points in $polygons)
    {
        [void]$Builder.AppendLine('    <polygon points="' + $points + '" fill="' + $Series.Color + '" fill-opacity="0.28" stroke="none"/>')
    }
    foreach ($points in $lines)
    {
        [void]$Builder.AppendLine('    <polyline points="' + $points + '" fill="none" stroke="' + $Series.Color + '" stroke-width="2" stroke-opacity="0.8"/>')
    }
}

Function Add-PalLineGeometry
{
    param($Builder, $Series, [int]$SampleCount, $Scale, [double]$Left, [double]$Top, [double]$PlotWidth, [double]$PlotHeight, [int]$MaxPoints = 1600)

    $ys = ConvertTo-PalDoubleArray $Series.YValues
    $limit = [math]::Min($ys.Length, $SampleCount)
    $indexes = Get-PalPlotIndexes -Values $ys -MaxPoints $MaxPoints
    $t = New-PalPlotTransform -SampleCount $SampleCount -Scale $Scale -Left $Left -Top $Top -PlotWidth $PlotWidth -PlotHeight $PlotHeight
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $xOffset = [double]$t.XOffset; $xStep = [double]$t.XStep; $yMax = [double]$t.YMax; $yFactor = [double]$t.YFactor; $top = [double]$t.Top

    $segment = New-Object System.Collections.Generic.List[string]
    $width = 2.5
    if ($null -ne $Series.PSObject.Properties['BorderWidth'] -and $Series.BorderWidth -gt 0) { $width = [double]$Series.BorderWidth }
    $dash = ConvertTo-PalDashArray -DashStyle $Series.DashStyle -Width $width
    $dashAttr = ''
    if ($dash -ne '') { $dashAttr = ' stroke-dasharray="' + $dash + '"' }
    $lineOpen = '    <polyline points="'
    $lineClose = '" fill="none" stroke="' + $Series.Color + '" stroke-width="' + (Format-SvgNumber $width) + '" stroke-linejoin="round" stroke-linecap="round"' + $dashAttr + '/>'
    $dotRadius = Format-SvgNumber ([math]::Max(2.5, $width))

    for ($n = 0; $n -le $indexes.Length; $n++)
    {
        $hasPoint = $false
        if ($n -lt $indexes.Length)
        {
            $i = $indexes[$n]
            if ($i -lt $limit)
            {
                $v = $ys[$i]
                if (-not [double]::IsNaN($v))
                {
                    [void]$segment.Add(($xOffset + ($i * $xStep)).ToString('0.##', $inv) + ',' + ($top + (($yMax - $v) * $yFactor)).ToString('0.##', $inv))
                    $hasPoint = $true
                }
            }
        }
        if ((-not $hasPoint) -or ($n -eq $indexes.Length))
        {
            if ($segment.Count -ge 2)
            {
                [void]$Builder.AppendLine($lineOpen + ($segment -join ' ') + $lineClose)
            }
            elseif ($segment.Count -eq 1)
            {
                $parts = $segment[0].Split(',')
                [void]$Builder.AppendLine('    <circle cx="' + $parts[0] + '" cy="' + $parts[1] + '" r="' + $dotRadius + '" fill="' + $Series.Color + '"/>')
            }
            $segment.Clear()
        }
    }
}

Function Write-PalChart
{
    param($ChartTitle, $SaveFilePath, $SeriesObjects)

    $seriesList = @($SeriesObjects | Where-Object { $null -ne $_ })
    $sampleCount = 0
    $xLabels = @()
    $numericCount = 0
    $min = [double]::MaxValue
    $max = [double]::MinValue
    foreach ($series in $seriesList)
    {
        $xs = @($series.XValues)
        if ($xs.Count -gt $sampleCount)
        {
            $sampleCount = $xs.Count
            $xLabels = $xs
        }
        foreach ($values in @((ConvertTo-PalDoubleArray $series.YValues), (ConvertTo-PalDoubleArray $series.Y2Values)))
        {
            foreach ($v in $values)
            {
                if ([double]::IsNaN($v)) { continue }
                $numericCount++
                if ($v -lt $min) { $min = $v }
                if ($v -gt $max) { $max = $v }
            }
        }
        $ys = @($series.YValues)
        if ($ys.Count -gt $sampleCount) { $sampleCount = $ys.Count }
    }
    if ($sampleCount -lt 1) { $sampleCount = 1 }

    $width = 960.0
    $left = 76.0
    $right = 22.0
    $top = 48.0
    $plotHeight = 340.0
    $axisBand = 58.0
    $legendColumns = 2
    if ($seriesList.Count -le 1) { $legendColumns = 1 }
    $legendRows = 1
    if ($seriesList.Count -gt 0) { $legendRows = [int][math]::Ceiling($seriesList.Count / [double]$legendColumns) }
    $legendHeight = 16 + ($legendRows * 22)
    $height = $top + $plotHeight + $axisBand + $legendHeight + 8
    $plotWidth = $width - $left - $right
    $plotBottom = $top + $plotHeight

    $culture = Get-PalChartCulture
    $scale = $null
    if ($numericCount -eq 0)
    {
        $scale = Get-PalAxisScale -Min 0 -Max 1
    }
    else
    {
        $scale = Get-PalAxisScale -Min $min -Max $max
    }

    $includeDate = $false
    $firstTime = $null
    $lastTime = $null
    foreach ($label in $xLabels)
    {
        if ($null -eq $label) { continue }
        $parsed = [datetime]::MinValue
        $ok = $false
        if ($label -is [datetime]) { $parsed = $label; $ok = $true }
        elseif ([datetime]::TryParse([string]$label, [ref]$parsed)) { $ok = $true }
        if ($ok)
        {
            if ($null -eq $firstTime) { $firstTime = $parsed }
            $lastTime = $parsed
        }
    }
    if ($null -ne $firstTime -and $null -ne $lastTime -and $firstTime.Date -ne $lastTime.Date) { $includeDate = $true }

    $xInterval = 0
    $chartSettings = Get-Variable -Name ChartSettings -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $chartSettings -and $null -ne $chartSettings.Value)
    {
        $xi = $chartSettings.Value.PSObject.Properties['XInterval']
        if ($null -ne $xi -and $xi.Value -gt 1) { $xInterval = [int]$xi.Value }
    }
    $maxLabels = 8
    $maxVar = $null
    if ($null -ne $chartSettings -and $null -ne $chartSettings.Value)
    {
        $maxVar = $chartSettings.Value.PSObject.Properties['XIntervalMax']
    }
    if ($null -ne $maxVar -and $maxVar.Value -gt 2 -and $maxVar.Value -lt 12) { $maxLabels = [int]$maxVar.Value }
    if ($maxLabels -gt 8) { $maxLabels = 8 }
    $labelStep = [math]::Max(1, [int][math]::Ceiling($sampleCount / [double]$maxLabels))
    if ($xInterval -gt $labelStep) { $labelStep = $xInterval }

    $clipId = 'plot' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine('<svg xmlns="http://www.w3.org/2000/svg" width="' + (Format-SvgNumber $width) + '" height="' + (Format-SvgNumber $height) + '" viewBox="0 0 ' + (Format-SvgNumber $width) + ' ' + (Format-SvgNumber $height) + '" role="img">')
    [void]$sb.AppendLine('  <title>' + (ConvertTo-PalXmlText $ChartTitle) + '</title>')
    [void]$sb.AppendLine('  <rect width="100%" height="100%" fill="#ffffff"/>')
    [void]$sb.AppendLine('  <text x="' + (Format-SvgNumber ($width / 2)) + '" y="28" text-anchor="middle" font-family="Segoe UI, Tahoma, Arial, sans-serif" font-size="16" font-weight="600" fill="#1c2430">' + (ConvertTo-PalXmlText $ChartTitle) + '</text>')
    [void]$sb.AppendLine('  <rect x="' + (Format-SvgNumber $left) + '" y="' + (Format-SvgNumber $top) + '" width="' + (Format-SvgNumber $plotWidth) + '" height="' + (Format-SvgNumber $plotHeight) + '" fill="#f6f8fb" stroke="#d5dbe3"/>')

    foreach ($tick in @($scale.Ticks))
    {
        $y = Get-PalPlotY -Value $tick -Min $scale.Min -Max $scale.Max -Top $top -Height $plotHeight
        $yText = Format-SvgNumber $y
        [void]$sb.AppendLine('  <line x1="' + (Format-SvgNumber $left) + '" y1="' + $yText + '" x2="' + (Format-SvgNumber ($left + $plotWidth)) + '" y2="' + $yText + '" stroke="#e1e6ee"/>')
        [void]$sb.AppendLine('  <text x="' + (Format-SvgNumber ($left - 8)) + '" y="' + (Format-SvgNumber ($y + 4)) + '" text-anchor="end" font-family="Segoe UI, Tahoma, Arial, sans-serif" font-size="11" fill="#4d5968">' + (ConvertTo-PalXmlText (Format-PalTick -Value $tick -Step $scale.Step -Culture $culture)) + '</text>')
    }

    if ($scale.Min -le 0 -and $scale.Max -ge 0)
    {
        $zeroY = Format-SvgNumber (Get-PalPlotY -Value 0 -Min $scale.Min -Max $scale.Max -Top $top -Height $plotHeight)
        [void]$sb.AppendLine('  <line x1="' + (Format-SvgNumber $left) + '" y1="' + $zeroY + '" x2="' + (Format-SvgNumber ($left + $plotWidth)) + '" y2="' + $zeroY + '" stroke="#9aa6b4" stroke-width="1"/>')
    }

    for ($i = 0; $i -lt $sampleCount; $i += $labelStep)
    {
        $x = Get-PalPlotX -Index $i -Count $sampleCount -Left $left -Width $plotWidth
        $xText = Format-SvgNumber $x
        [void]$sb.AppendLine('  <line x1="' + $xText + '" y1="' + (Format-SvgNumber $top) + '" x2="' + $xText + '" y2="' + (Format-SvgNumber $plotBottom) + '" stroke="#e7ebf1"/>')
        $label = ''
        if ($i -lt @($xLabels).Count -and $null -ne $xLabels[$i])
        {
            $parsed = [datetime]::MinValue
            if ($xLabels[$i] -is [datetime]) { $label = $(if ($includeDate) { $xLabels[$i].ToString('MM-dd HH:mm') } else { $xLabels[$i].ToString('HH:mm:ss') }) }
            elseif ([datetime]::TryParse([string]$xLabels[$i], [ref]$parsed)) { $label = $(if ($includeDate) { $parsed.ToString('MM-dd HH:mm') } else { $parsed.ToString('HH:mm:ss') }) }
            else { $label = [string]$xLabels[$i] }
        }
        if ($label -ne '')
        {
            $tx = Format-SvgNumber ($x)
            $ty = Format-SvgNumber ($plotBottom + 8)
            [void]$sb.AppendLine('  <text transform="translate(' + $tx + ' ' + $ty + ') rotate(40)" text-anchor="start" font-family="Segoe UI, Tahoma, Arial, sans-serif" font-size="11" fill="#4d5968">' + (ConvertTo-PalXmlText $label) + '</text>')
        }
    }

    [void]$sb.AppendLine('  <defs><clipPath id="' + $clipId + '"><rect x="' + (Format-SvgNumber $left) + '" y="' + (Format-SvgNumber $top) + '" width="' + (Format-SvgNumber $plotWidth) + '" height="' + (Format-SvgNumber $plotHeight) + '"/></clipPath></defs>')
    [void]$sb.AppendLine('  <g clip-path="url(#' + $clipId + ')">')
    if ($numericCount -eq 0)
    {
        [void]$sb.AppendLine('    <text x="' + (Format-SvgNumber ($left + ($plotWidth / 2))) + '" y="' + (Format-SvgNumber ($top + ($plotHeight / 2))) + '" text-anchor="middle" font-family="Segoe UI, Tahoma, Arial, sans-serif" font-size="14" fill="#667384">No numeric samples</text>')
    }
    else
    {
        foreach ($series in $seriesList)
        {
            if ($series.ChartType -eq 'Range' -and $series.Name -eq 'Critical')
            {
                Add-PalRangeGeometry -Builder $sb -Series $series -SampleCount $sampleCount -Scale $scale -Left $left -Top $top -PlotWidth $plotWidth -PlotHeight $plotHeight
            }
        }
        foreach ($series in $seriesList)
        {
            if ($series.ChartType -eq 'Range' -and $series.Name -ne 'Critical')
            {
                Add-PalRangeGeometry -Builder $sb -Series $series -SampleCount $sampleCount -Scale $scale -Left $left -Top $top -PlotWidth $plotWidth -PlotHeight $plotHeight
            }
        }
        foreach ($series in $seriesList)
        {
            if ($series.ChartType -ne 'Range')
            {
                Add-PalLineGeometry -Builder $sb -Series $series -SampleCount $sampleCount -Scale $scale -Left $left -Top $top -PlotWidth $plotWidth -PlotHeight $plotHeight
            }
        }
    }
    [void]$sb.AppendLine('  </g>')

    $legendTop = $plotBottom + $axisBand
    $legendWidth = ($width - 40) / $legendColumns
    for ($i = 0; $i -lt $seriesList.Count; $i++)
    {
        $series = $seriesList[$i]
        $col = $i % $legendColumns
        $row = [math]::Floor($i / $legendColumns)
        $x = 24 + ($col * $legendWidth)
        $y = $legendTop + ($row * 22)
        $label = [string]$series.Name
        if ($label.Length -gt 62) { $label = $label.Substring(0, 59) + '...' }
        if ($series.ChartType -eq 'Range')
        {
            [void]$sb.AppendLine('  <rect x="' + (Format-SvgNumber $x) + '" y="' + (Format-SvgNumber ($y + 2)) + '" width="22" height="10" fill="' + $series.Color + '" fill-opacity="0.45" stroke="' + $series.Color + '"/>')
        }
        else
        {
            $dash = ConvertTo-PalDashArray -DashStyle $series.DashStyle -Width 2.5
            $dashAttr = ''
            if ($dash -ne '') { $dashAttr = ' stroke-dasharray="' + $dash + '"' }
            [void]$sb.AppendLine('  <line x1="' + (Format-SvgNumber $x) + '" y1="' + (Format-SvgNumber ($y + 7)) + '" x2="' + (Format-SvgNumber ($x + 22)) + '" y2="' + (Format-SvgNumber ($y + 7)) + '" stroke="' + $series.Color + '" stroke-width="2.5"' + $dashAttr + '/>')
        }
        [void]$sb.AppendLine('  <text x="' + (Format-SvgNumber ($x + 28)) + '" y="' + (Format-SvgNumber ($y + 12)) + '" font-family="Segoe UI, Tahoma, Arial, sans-serif" font-size="12" fill="#1c2430">' + (ConvertTo-PalXmlText $label) + '<title>' + (ConvertTo-PalXmlText $series.Name) + '</title></text>')
    }

    [void]$sb.AppendLine('</svg>')
    $directory = Split-Path -Parent $SaveFilePath
    if (($directory -ne '') -and (-not (Test-Path -Path $directory)))
    {
        [void](New-Item -Path $directory -ItemType Directory -Force)
    }
    $encoding = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($SaveFilePath, $sb.ToString(), $encoding)
    return $SaveFilePath
}

Function CreatePalCharts
{
    param([System.Collections.ArrayList] $ArrayListOfCounterSeries, [System.Collections.ArrayList] $ArrayListOfThresholdSeries, [System.Int32] $MaxNumberOfItemsInChart = 10, [System.String] $OutputDirectoryPath = '', [System.String] $ImageFileName = '', [System.String] $ChartTitle = '')
    $alOfChartFilesPaths = New-Object System.Collections.ArrayList

    if ($ArrayListOfCounterSeries.Count -eq 0)
    {
        return $alOfChartFilesPaths
    }

    [System.Int32] $a = 0
    [System.Int32] $iChartNumber = 0
    [System.String] $sFilePath = ''
    if ($MaxNumberOfItemsInChart -lt 1) { $MaxNumberOfItemsInChart = 1 }
    do
    {
        $alNewChartSeries = New-Object System.Collections.ArrayList
        for ($t = 0; $t -lt $ArrayListOfThresholdSeries.Count; $t++)
        {
            [void]$alNewChartSeries.Add($ArrayListOfThresholdSeries[$t])
        }
        $added = 0
        while (($a -lt $ArrayListOfCounterSeries.Count) -and ($added -lt $MaxNumberOfItemsInChart))
        {
            [void]$alNewChartSeries.Add($ArrayListOfCounterSeries[$a])
            $a++
            $added++
        }

        $iChartNumber = 0
        $bFileExists = $true
        do
        {
            $sFilePath = $OutputDirectoryPath + $ImageFileName + "$iChartNumber" + '.svg'
            $bFileExists = Test-Path -Path $sFilePath
            $iChartNumber++
        } until ($bFileExists -eq $false)
        $sFilePath = Write-PalChart -ChartTitle $ChartTitle -SaveFilePath $sFilePath -SeriesObjects $alNewChartSeries
        [void]$alOfChartFilesPaths.Add($sFilePath)
    } until ($a -ge $ArrayListOfCounterSeries.Count)
    return $alOfChartFilesPaths
}
