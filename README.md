# Performance Analysis of Logs (PAL) Tool
[![licence badge]][licence]
[![stars badge]][stars]
[![forks badge]][forks]
[![issues badge]][issues]

[licence badge]:https://img.shields.io/badge/license-MIT-blue.svg
[stars badge]:https://img.shields.io/github/stars/jeffstokes72/PAL.svg
[forks badge]:https://img.shields.io/github/forks/jeffstokes72/PAL.svg
[issues badge]:https://img.shields.io/github/issues/jeffstokes72/PAL.svg

[licence]:https://github.com/jeffstokes72/PAL/blob/master/LICENSE.md
[stars]:https://github.com/jeffstokes72/PAL/stargazers
[forks]:https://github.com/jeffstokes72/PAL/network
[issues]:https://github.com/jeffstokes72/PAL/issues

This repository is a maintained fork of [clinthuffman/PAL](https://github.com/clinthuffman/PAL). It keeps PAL working on current Windows releases; the original project is no longer updated.

## Created by Clint Huffman

PAL was created by [Clint Huffman](https://github.com/clinthuffman). Clint is a Senior Microsoft Premier Field Engineer and the author of the *Windows Performance Analysis Field Guide*. He started this project in 2007 so that working IT pros could analyze a Performance Monitor log with the same discipline he used on customer engagements.

He has spent his career making Windows performance understandable. As a Premier Field Engineer he sat with customers, read their counter logs, and turned what he found into guidance other administrators could reuse. He taught the Vital Signs workshop, wrote about the cases he saw in the field, and published the counter thresholds behind products such as IIS, SQL Server, Exchange, BizTalk, and Active Directory. PAL is the piece he gave away: a free tool, an open threshold library, and an HTML report that tells you which counters mattered and why. The copyright on this repository is his. The license is the MIT License, Copyright (c) 2017 Clint Huffman.

That body of work is still the heart of this project. The threshold files, the questions the wizard asks, and the shape of the report all come from Clint's field experience and from his choice to share it. Other people have contributed files and fixes along the way. The tool itself, and the years of teaching behind it, are his contribution to the IT pro community.

A short account in his own words is on his [About the Author](https://learn.microsoft.com/en-us/archive/blogs/clinth/about-the-author-clint-huffman) page.

## Project Description
Ever have a performance problem, but don't know what performance counters to collect or how to analyze them?
The PAL (Performance Analysis of Logs) tool reads a performance monitor counter log and analyzes it using known thresholds.

## Features
 - Thresholds files for most of the major Microsoft products such as IIS, MOSS, SQL Server, BizTalk, Exchange, and Active Directory.
 - An easy to use GUI interface which makes creating batch files for the PAL.ps1 script.
 - A GUI editor for creating or editing your own threshold files.
 - Creates an HTML report, with SVG charts, for ease of copy/pasting into other applications.
 - Analyzes performance counter logs for thresholds using thresholds that change their criteria based on the computer's role or hardware specs.
 
## Requirements
Windows 10, Windows 11, or Windows Server 2016 or later, with Windows PowerShell 5.1 (inbox) or PowerShell 7 and the .NET Framework 4.7.2 or later (inbox on Windows 10 1803+ and Windows 11). The analysis script is `PAL.ps1`. Charts in the HTML report are self-contained SVG drawings produced by that script, so no chart controls need to be installed. Log conversion uses the inbox `relog.exe`.

## How to download

**Option 1: release zip.** Download the latest `PAL_FlatFiles_<version>.zip` from this repository's [releases page](https://github.com/jeffstokes72/PAL/releases). Right-click the zip, choose Properties, tick **Unblock**, click OK, extract it to a new empty folder, and run `PALWizard.exe`. No installer is required.

**Option 2: run from a checkout.** Clone this repository or use **Code → Download ZIP**, unblock and extract it, then run `PAL2\PALWizard\bin\Debug\PALWizard.exe`. That folder contains everything PAL needs: the wizard, `PAL.ps1`, `PalCharts.ps1`, and the threshold files.

Older `PAL_FlatFiles_*.zip` files in the repository root are previous releases kept for reference.

The MSI installer (`PAL2/PALSetup`) is not produced by the automated build because it requires the Visual Studio Installer Projects extension. Build it in Visual Studio if you need an installer.

## How releases are built
Every push runs the [Build PAL](.github/workflows/build.yml) workflow on a Windows runner: it compiles `PALWizard.exe`, runs `PAL2/PALWizard/tests/Test-PalCharts.ps1` under both Windows PowerShell 5.1 and PowerShell 7, and uploads the flat-file zip as a build artifact. Pushing a tag such as `v2.8.3` publishes that zip as a GitHub Release.

## How to use
Run `PALWizard.exe` to use the PAL Wizard. It finds the counter log, asks a few questions about the computer, and writes a batch file that runs `PAL.ps1`. You can also run the script directly:

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File .\PAL.ps1 -Log "C:\PerfLogs\server.blg" -ThresholdFile QuickSystemOverview.xml
```

Reports are written to `Documents\PAL Reports` by default.

## Feedback
Your feedback is welcome via the [issues section](https://github.com/jeffstokes72/PAL/issues)

## Contributing
Your contributions are very welcome by submitting a Pull Request. Please keep Clint Huffman's attribution in the report header, the script header, and this README when you do.
