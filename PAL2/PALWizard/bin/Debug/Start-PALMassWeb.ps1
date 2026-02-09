param(
    [Parameter()][int] $Port = 8787,
    [Parameter()][string] $PalScriptPath,
    [Parameter()][string] $DefaultInputPath,
    [Parameter()][string] $DefaultOutputRoot,
    [Parameter()][int] $DefaultThrottleLimit = 4,
    [Parameter()][int] $DefaultPalThreads = 4,
    [Parameter()][string] $DefaultAnalysisInterval = "AUTO",
    [Parameter()][switch] $NoBrowser
)

Set-StrictMode -Version 2

. (Join-Path -Path $PSScriptRoot -ChildPath "PALMass.ps1")
Test-Ps7OrHigher

if (-not $IsWindows) {
    throw "Start-PALMassWeb.ps1 is intended for Windows (BLG + PAL dependencies). Use Invoke-PALMass.ps1 for headless runs if applicable."
}

$PalScriptPath = Resolve-PalScriptPath -PalScriptPath $PalScriptPath -PalRoot $PSScriptRoot
$palRoot = Split-Path -Parent $PalScriptPath

if ([string]::IsNullOrWhiteSpace($DefaultInputPath)) {
    if ($IsWindows) { $DefaultInputPath = "C:\\" } else { $DefaultInputPath = (Get-Location).Path }
}
if ([string]::IsNullOrWhiteSpace($DefaultOutputRoot)) {
    $DefaultOutputRoot = Join-Path -Path (Get-Location).Path -ChildPath ("PAL_Mass_Web_" + (Get-Date).ToString("yyyyMMdd_HHmmss"))
}

function Get-AvailableThresholdXmls([string] $root) {
    $exclude = @(
        "All.xml","AutoDetect.xml","CalculatedIops.xml","Custom.xml","ICIPThresholds.xml",
        "PALFunctions.xml","PALWizard.xml","CounterLang.xml","PAL_VMwareView_PCoIP.xml","PAL_VMwareView_VDM.xml"
    )
    Get-ChildItem -LiteralPath $root -File -Filter "*.xml" -ErrorAction SilentlyContinue |
        Where-Object { $exclude -notcontains $_.Name } |
        Sort-Object -Property Name |
        Select-Object -ExpandProperty Name
}

$availableXmls = @(Get-AvailableThresholdXmls -root $palRoot)
$defaultThresholds = @("QuickSystemOverview.xml","SystemOverview.xml","VMWare.xml") | Where-Object { $availableXmls -contains $_ }
if ($defaultThresholds.Count -eq 0 -and $availableXmls.Count -gt 0) {
    $defaultThresholds = @($availableXmls | Select-Object -First 3)
}

$global:PALMassWebJob = $null
$global:PALMassWebOutputRoot = $null
$global:PALMassWebStatusPath = $null

function Send-Json($ctx, $obj, [int] $statusCode = 200) {
    $ctx.Response.StatusCode = $statusCode
    $ctx.Response.ContentType = "application/json; charset=utf-8"
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 8))
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Send-Text($ctx, [string] $text, [string] $contentType = "text/plain; charset=utf-8", [int] $statusCode = 200) {
    $ctx.Response.StatusCode = $statusCode
    $ctx.Response.ContentType = $contentType
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Read-BodyJson($ctx) {
    $sr = New-Object IO.StreamReader($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
    $raw = $sr.ReadToEnd()
    $sr.Close()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Get-SafeLocalPathFromUrl([string] $basePath, [string] $urlPath) {
    # urlPath is like /out/foo/bar/report.htm
    $rel = $urlPath.Substring("/out/".Length)
    $rel = $rel -replace '/', [IO.Path]::DirectorySeparatorChar
    $combined = Join-Path -Path $basePath -ChildPath $rel
    $full = [IO.Path]::GetFullPath($combined)
    $base = [IO.Path]::GetFullPath($basePath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar)
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $full
}

$script:html = @'
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>PAL Mass Processing Web Launcher</title>
  <style>
    body { font: 14px/20px Segoe UI, Arial, sans-serif; margin: 18px; }
    h1 { margin-bottom: 6px; }
    .row { margin: 10px 0; }
    input[type=text] { width: 720px; padding: 6px; }
    button { padding: 8px 12px; }
    .box { border: 1px solid #ddd; padding: 10px; border-radius: 6px; }
    .muted { color: #555; }
    .pill { display:inline-block; padding:2px 8px; border-radius:12px; font-size:12px; border:1px solid #ddd; background:#f7f7f7; }
    #tree ul { list-style: none; padding-left: 18px; }
    #tree li { margin: 2px 0; }
    code { background:#f7f7f7; padding: 1px 4px; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>PAL Mass Processing Web Launcher</h1>
  <div class="muted">
    This launches mass processing for all <code>.blg</code> files under selected directories, runs PAL with <b>AllCounterStats</b>, and produces a mirrored output tree plus a master report.
  </div>

  <div class="row box">
    <div class="row">
      <div><b>Root path</b> (directory tree to scan)</div>
      <input id="rootPath" type="text" />
      <button onclick="loadTree()">Load tree</button>
    </div>

    <div class="row">
      <div><b>Output root</b></div>
      <input id="outputRoot" type="text" />
    </div>

    <div class="row">
      <div><b>Threshold XML files</b> (default picks at least QuickSystemOverview, SystemOverview, VMWare)</div>
      <div id="thresholds"></div>
    </div>

    <div class="row">
      <div>
        <b>Concurrency</b>
        <span class="pill">ThrottleLimit = <input id="throttle" type="text" value="4" style="width:60px" /></span>
        <span class="pill">PAL Threads = <input id="palthreads" type="text" value="4" style="width:60px" /></span>
        <span class="pill">Interval = <input id="interval" type="text" value="AUTO" style="width:80px" /></span>
      </div>
    </div>

    <div class="row">
      <button onclick="startRun()">Start processing selected directories</button>
    </div>
  </div>

  <div class="row box">
    <div><b>Select directories</b> (checked dirs will be scanned recursively)</div>
    <div id="tree" class="muted">Load a tree to begin.</div>
  </div>

  <div class="row box">
    <div><b>Status</b></div>
    <pre id="status" class="muted">Idle</pre>
    <div id="links"></div>
  </div>

<script>
let config = null;
let selectedDirs = new Set();

async function fetchConfig() {
  const r = await fetch('/api/config');
  config = await r.json();
  document.getElementById('rootPath').value = config.defaultInputPath;
  document.getElementById('outputRoot').value = config.defaultOutputRoot;
  document.getElementById('throttle').value = config.defaultThrottleLimit;
  document.getElementById('palthreads').value = config.defaultPalThreads;
  document.getElementById('interval').value = config.defaultAnalysisInterval;

  const tdiv = document.getElementById('thresholds');
  tdiv.innerHTML = '';
  for (const name of config.availableThresholdXmls) {
    const id = 'thr_' + name.replace(/[^a-zA-Z0-9]/g,'_');
    const checked = config.defaultThresholdXmls.includes(name) ? 'checked' : '';
    tdiv.innerHTML += `<div><label><input type="checkbox" id="${id}" data-name="${name}" ${checked}/> ${name}</label></div>`;
  }
}

function getSelectedThresholds() {
  const boxes = document.querySelectorAll('#thresholds input[type=checkbox]');
  const sel = [];
  boxes.forEach(b => { if (b.checked) sel.push(b.getAttribute('data-name')); });
  return sel;
}

function toggleDir(path, checked) {
  if (checked) selectedDirs.add(path); else selectedDirs.delete(path);
}

async function loadTree() {
  selectedDirs = new Set();
  const root = document.getElementById('rootPath').value;
  const treeDiv = document.getElementById('tree');
  treeDiv.textContent = 'Loading...';
  const r = await fetch('/api/tree?path=' + encodeURIComponent(root));
  const data = await r.json();
  treeDiv.innerHTML = renderTree(data);
}

function renderTree(data) {
  if (data.error) return `<div style="color:#b00020"><b>Error:</b> ${data.error}</div>`;
  let html = `<div><b>Root:</b> <code>${data.path}</code></div>`;
  html += '<ul>';
  html += `<li><label><input type="checkbox" onchange="toggleDir('${escapeJs(data.path)}', this.checked)" /> (select root)</label></li>`;
  for (const d of data.dirs) {
    html += `<li>
      <details>
        <summary>
          <label>
            <input type="checkbox" onchange="toggleDir('${escapeJs(d.fullPath)}', this.checked)" />
            ${d.name} <span class="pill">blg (direct): ${d.blgCountDirect}</span>
          </label>
        </summary>
        <div id="node_${escapeHtmlId(d.fullPath)}" class="muted">Loading...</div>
      </details>
    </li>`;
  }
  html += '</ul>';

  // Hook up lazy loaders
  setTimeout(() => {
    for (const d of data.dirs) {
      const nodeId = 'node_' + escapeHtmlId(d.fullPath);
      const el = document.getElementById(nodeId);
      if (!el) continue;
      // Load children when details opens
      const details = el.closest('details');
      details.addEventListener('toggle', async () => {
        if (!details.open) return;
        if (el.getAttribute('data-loaded') === '1') return;
        el.textContent = 'Loading...';
        const r2 = await fetch('/api/tree?path=' + encodeURIComponent(d.fullPath));
        const child = await r2.json();
        el.innerHTML = renderTreeChildren(child);
        el.setAttribute('data-loaded','1');
      });
      el.textContent = '(expand to load)';
    }
  }, 0);

  return html;
}

function renderTreeChildren(data) {
  if (data.error) return `<div style="color:#b00020"><b>Error:</b> ${data.error}</div>`;
  let html = '<ul>';
  for (const sub of data.dirs) {
    html += `<li>
      <details>
        <summary>
          <label>
            <input type="checkbox" onchange="toggleDir('${escapeJs(sub.fullPath)}', this.checked)" />
            ${sub.name} <span class="pill">blg (direct): ${sub.blgCountDirect}</span>
          </label>
        </summary>
        <div id="node_${escapeHtmlId(sub.fullPath)}" class="muted">(expand to load)</div>
      </details>
    </li>`;
  }
  for (const f of data.blgFiles) {
    html += `<li class="muted">${f.name}</li>`;
  }
  html += '</ul>';

  // Same lazy behavior for newly created nodes
  setTimeout(() => {
    for (const sub of data.dirs) {
      const nodeId = 'node_' + escapeHtmlId(sub.fullPath);
      const el = document.getElementById(nodeId);
      if (!el) continue;
      const details = el.closest('details');
      details.addEventListener('toggle', async () => {
        if (!details.open) return;
        if (el.getAttribute('data-loaded') === '1') return;
        el.textContent = 'Loading...';
        const r2 = await fetch('/api/tree?path=' + encodeURIComponent(sub.fullPath));
        const child = await r2.json();
        el.innerHTML = renderTreeChildren(child);
        el.setAttribute('data-loaded','1');
      });
    }
  }, 0);

  return html;
}

function escapeHtmlId(s) { return s.replace(/[^a-zA-Z0-9]/g,'_'); }
function escapeJs(s) { return s.replace(/\\/g,'\\\\').replace(/'/g,"\\'"); }

async function startRun() {
  const inputDirs = Array.from(selectedDirs);
  if (inputDirs.length === 0) {
    alert('Select at least one directory (or select root).');
    return;
  }
  const payload = {
    inputPaths: inputDirs,
    outputRoot: document.getElementById('outputRoot').value,
    thresholdFiles: getSelectedThresholds(),
    throttleLimit: parseInt(document.getElementById('throttle').value || '4'),
    palThreads: parseInt(document.getElementById('palthreads').value || '4'),
    analysisInterval: document.getElementById('interval').value || 'AUTO'
  };
  const r = await fetch('/api/start', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload) });
  const resp = await r.json();
  document.getElementById('links').innerHTML = resp.masterUrl ? `<a href="${resp.masterUrl}">Open master report (when ready)</a>` : '';
  pollStatus();
}

async function pollStatus() {
  const r = await fetch('/api/status');
  const s = await r.json();
  document.getElementById('status').textContent = JSON.stringify(s, null, 2);
  if (s && s.masterUrl) {
    document.getElementById('links').innerHTML = `<a href="${s.masterUrl}">Open master report</a>`;
  }
  if (!s || !s.completedUtc) {
    setTimeout(pollStatus, 2000);
  }
}

fetchConfig().catch(e => { document.getElementById('status').textContent = String(e); });
</script>
</body>
</html>
'@

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
} catch {
    $msg = $_.Exception.Message
    throw "Failed to start HTTP listener on port $Port. $msg`nTry running PowerShell as Administrator, or reserve the URL ACL for the current user (e.g. netsh http add urlacl url=http://localhost:$Port/ user=$env:USERNAME)."
}

Write-Host "PAL Mass web launcher listening on http://localhost:$Port/"

if (-not $NoBrowser.IsPresent) {
    try { Start-Process -FilePath "http://localhost:$Port/" | Out-Null } catch { }
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        try {
            if ($path -eq "/") {
                Send-Text -ctx $ctx -text $script:html -contentType "text/html; charset=utf-8"
                continue
            }

            if ($path -eq "/api/config") {
                $obj = [ordered]@{
                    palRoot = $palRoot
                    palScriptPath = $PalScriptPath
                    availableThresholdXmls = $availableXmls
                    defaultThresholdXmls = $defaultThresholds
                    defaultInputPath = $DefaultInputPath
                    defaultOutputRoot = $DefaultOutputRoot
                    defaultThrottleLimit = $DefaultThrottleLimit
                    defaultPalThreads = $DefaultPalThreads
                    defaultAnalysisInterval = $DefaultAnalysisInterval
                }
                Send-Json -ctx $ctx -obj $obj
                continue
            }

            if ($path -eq "/api/tree") {
                $q = $ctx.Request.QueryString["path"]
                if ([string]::IsNullOrWhiteSpace($q)) { Send-Json -ctx $ctx -obj @{ error="Missing query param 'path'." } -statusCode 400; continue }
                try {
                    if (-not (Test-Path -LiteralPath $q)) { Send-Json -ctx $ctx -obj @{ error="Path not found: $q" } -statusCode 404; continue }
                    $full = (Resolve-Path -LiteralPath $q).Path
                    $dirs = @()
                    Get-ChildItem -LiteralPath $full -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name | ForEach-Object {
                        $directBlg = @(Get-ChildItem -LiteralPath $_.FullName -File -Filter "*.blg" -ErrorAction SilentlyContinue).Count
                        $hasChild = $false
                        if (Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 1) { $hasChild = $true }
                        $dirs += [ordered]@{ name=$_.Name; fullPath=$_.FullName; hasChildren=$hasChild; blgCountDirect=$directBlg }
                    }
                    $blgFiles = @()
                    Get-ChildItem -LiteralPath $full -File -Filter "*.blg" -ErrorAction SilentlyContinue | Sort-Object -Property Name | ForEach-Object {
                        $blgFiles += [ordered]@{ name=$_.Name; fullPath=$_.FullName }
                    }
                    Send-Json -ctx $ctx -obj ([ordered]@{ path=$full; dirs=$dirs; blgFiles=$blgFiles })
                } catch {
                    Send-Json -ctx $ctx -obj @{ error = $_.Exception.Message } -statusCode 500
                }
                continue
            }

            if ($path -eq "/api/start" -and $ctx.Request.HttpMethod -eq "POST") {
                if ($global:PALMassWebJob -and $global:PALMassWebJob.State -eq "Running") {
                    Send-Json -ctx $ctx -obj @{ error="A run is already in progress." } -statusCode 409
                    continue
                }
                $body = Read-BodyJson -ctx $ctx
                if (-not $body) { Send-Json -ctx $ctx -obj @{ error="Missing JSON body." } -statusCode 400; continue }

                $out = [string]$body.outputRoot
                if ([string]::IsNullOrWhiteSpace($out)) { $out = $DefaultOutputRoot }
                New-Item -ItemType Directory -Path $out -Force | Out-Null

                $global:PALMassWebOutputRoot = (Resolve-Path -LiteralPath $out).Path
                $global:PALMassWebStatusPath = Join-Path -Path $global:PALMassWebOutputRoot -ChildPath "status.json"

                $inputPaths = @([string[]]$body.inputPaths)
                $thresholds = @([string[]]$body.thresholdFiles)
                $thr = [int]$body.throttleLimit
                $pt = [int]$body.palThreads
                $ai = [string]$body.analysisInterval
                if ($thr -le 0) { $thr = $DefaultThrottleLimit }
                if ($pt -le 0) { $pt = $DefaultPalThreads }
                if ([string]::IsNullOrWhiteSpace($ai)) { $ai = $DefaultAnalysisInterval }

                $global:PALMassWebJob = Start-Job -ScriptBlock {
                    param($psRoot, $inputPaths, $outputRoot, $palScriptPath, $thresholds, $thr, $pt, $ai, $statusPath)
                    Set-StrictMode -Version 2
                    . (Join-Path -Path $psRoot -ChildPath "PALMass.ps1")
                    Invoke-PalMass -InputPaths $inputPaths -OutputRoot $outputRoot -PalScriptPath $palScriptPath -ThresholdFiles $thresholds -ThrottleLimit $thr -PalThreads $pt -AnalysisInterval $ai -StatusPath $statusPath | Out-Null
                } -ArgumentList @($PSScriptRoot, $inputPaths, $global:PALMassWebOutputRoot, $PalScriptPath, $thresholds, $thr, $pt, $ai, $global:PALMassWebStatusPath)

                $resp = [ordered]@{
                    started = $true
                    outputRoot = $global:PALMassWebOutputRoot
                    statusUrl = "/api/status"
                    masterUrl = "/out/index.html"
                }
                Send-Json -ctx $ctx -obj $resp
                continue
            }

            if ($path -eq "/api/status") {
                if ($global:PALMassWebStatusPath -and (Test-Path -LiteralPath $global:PALMassWebStatusPath)) {
                    try {
                        $st = Get-Content -LiteralPath $global:PALMassWebStatusPath -Raw | ConvertFrom-Json
                        $st | Add-Member -NotePropertyName "masterUrl" -NotePropertyValue "/out/index.html" -Force
                        Send-Json -ctx $ctx -obj $st
                    } catch {
                        Send-Json -ctx $ctx -obj @{ error = $_.Exception.Message } -statusCode 500
                    }
                } else {
                    $jobState = if ($global:PALMassWebJob) { $global:PALMassWebJob.State } else { "Idle" }
                    Send-Json -ctx $ctx -obj @{ state=$jobState }
                }
                continue
            }

            if ($path.StartsWith("/out/")) {
                if (-not $global:PALMassWebOutputRoot) { Send-Text -ctx $ctx -text "No output root yet." -statusCode 404; continue }
                $local = Get-SafeLocalPathFromUrl -basePath $global:PALMassWebOutputRoot -urlPath $path
                if (-not $local) { Send-Text -ctx $ctx -text "Invalid path." -statusCode 400; continue }
                if (-not (Test-Path -LiteralPath $local)) { Send-Text -ctx $ctx -text "Not found." -statusCode 404; continue }

                $ext = [IO.Path]::GetExtension($local).ToLowerInvariant()
                $ctype = "application/octet-stream"
                switch ($ext) {
                    ".html" { $ctype = "text/html; charset=utf-8" }
                    ".htm"  { $ctype = "text/html; charset=utf-8" }
                    ".css"  { $ctype = "text/css; charset=utf-8" }
                    ".js"   { $ctype = "application/javascript; charset=utf-8" }
                    ".json" { $ctype = "application/json; charset=utf-8" }
                    ".csv"  { $ctype = "text/csv; charset=utf-8" }
                    ".png"  { $ctype = "image/png" }
                    ".jpg"  { $ctype = "image/jpeg" }
                    ".jpeg" { $ctype = "image/jpeg" }
                    ".gif"  { $ctype = "image/gif" }
                    ".xml"  { $ctype = "application/xml; charset=utf-8" }
                }

                $bytes = [IO.File]::ReadAllBytes($local)
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentType = $ctype
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.OutputStream.Close()
                continue
            }

            Send-Text -ctx $ctx -text "Not found." -statusCode 404
        } catch {
            try { Send-Text -ctx $ctx -text ("Server error: " + $_.Exception.Message) -statusCode 500 } catch { }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
}

