# Performance Analysis of Logs (PAL) Tool
[![licence badge]][licence]
[![stars badge]][stars]
[![forks badge]][forks]
[![issues badge]][issues]

[licence badge]:https://img.shields.io/badge/license-MIT-blue.svg
[stars badge]:https://img.shields.io/github/stars/clinthuffman/PAL.svg
[forks badge]:https://img.shields.io/github/forks/clinthuffman/PAL.svg
[issues badge]:https://img.shields.io/github/issues/clinthuffman/PAL.svg

[licence]:https://github.com/clinthuffman/PAL/blob/master/LICENSE.md
[stars]:https://github.com/clinthuffman/PAL/stargazers
[forks]:https://github.com/clinthuffman/PAL/network
[issues]:https://github.com/clinthuffman/PAL/issues

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
 Run PAL on Windows with Windows PowerShell 5.1 and the Microsoft .NET Framework 4.7.2 feature enabled. The analysis script is `PAL.ps1`. Charts in the HTML report are self-contained SVG drawings produced by that script.

## How to download
If you wish to install the PAL tool, then download `PAL_Setup`. It contains the Microsoft installer files. Right-click and go to Properties of the zip file, select Unblock, and then click OK. Extract the zip file to a new, empty folder, and then run Setup.

If you just want to run it without installation, then download `PAL_FlatFile`. Right-click and go to Properties of the zip file, select Unblock, and then click OK. Extract the zip file to a new, empty folder, and then run PALWizard.exe to use the tool.

Both files can be downloaded from the [releases section](https://github.com/clinthuffman/PAL/releases)

## How to use
Run PALWizard.exe to use the PAL Wizard tool. Otherwise, use PAL.ps1 directly.

## Feedback
Your feedback is welcome via the [issues section](https://github.com/clinthuffman/PAL/issues)

## Contributing
Your contributions are very welcome by submitting a Pull Request. Please keep Clint Huffman's attribution in the report header, the script header, and this README when you do.
