# Renders a diagram script to SVG, PNG (2x) and PDF using Microsoft Edge.
# Usage: .\build.ps1 existing_process_flowchart
param([string]$Name = "existing_process_flowchart")

# Edge writes harmless warnings to stderr, so don't treat those as failures.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
python "$Name.py"

$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$svg = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "$Name.svg"), [Text.Encoding]::UTF8)
$m = [regex]::Match($svg, 'width="(\d+)" height="(\d+)"')
$w = $m.Groups[1].Value; $h = $m.Groups[2].Value

function Render([string]$html, [string[]]$edgeArgs) {
  $tmp = Join-Path $PSScriptRoot "_render.html"
  [IO.File]::WriteAllText($tmp, $html)
  $url = "file:///" + ($tmp -replace '\\', '/')
  & $edge --headless=new --disable-gpu --hide-scrollbars @edgeArgs $url 2>&1 | Out-Null
  Start-Sleep -Seconds 2
  Remove-Item $tmp
}

# PNG: the drawing scales to fit the viewport so nothing gets cut off.
$fit = $svg -replace '<svg xmlns="http://www.w3.org/2000/svg" width="\d+" height="\d+"',
  '<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" preserveAspectRatio="xMidYMid meet"'
Render "<!doctype html><html><head><meta charset='utf-8'><style>html,body{margin:0;width:100vw;height:100vh;overflow:hidden;background:#fff}svg{display:block}</style></head><body>$fit</body></html>" `
  @("--force-device-scale-factor=2", "--window-size=$w,$h", "--screenshot=$PSScriptRoot\$Name.png")

# PDF: one page exactly the size of the drawing.
Render "<!doctype html><html><head><meta charset='utf-8'><style>@page{size:${w}px ${h}px;margin:0}html,body{margin:0}svg{display:block}</style></head><body>$svg</body></html>" `
  @("--no-pdf-header-footer", "--print-to-pdf=$PSScriptRoot\$Name.pdf")

Get-ChildItem "$Name.*" | ForEach-Object { "{0} {1:N0} KB" -f $_.Name, ($_.Length / 1KB) }
