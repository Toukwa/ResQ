# =============================================================
# ResQ EOC - Firebase Hosting Deploy Script
# Run this after: flutter build web --release
# =============================================================

param(
  [string]$Version = "1.0.0",
  [switch]$SkipWebBuild
)

$ErrorActionPreference = "Stop"
$RootDir = $PSScriptRoot

Write-Host "`n[1/4] Checking build outputs..." -ForegroundColor Cyan

$ReleasePath = "$RootDir\build\windows\x64\runner\Release"
$InstallerPath = "$RootDir\installer\output\ResQ_EOC_Setup_v$Version.exe"
$ZipPath = "$RootDir\installer\ResQ_EOC_v${Version}_Windows.zip"

if (-not (Test-Path $ReleasePath)) {
  Write-Host "  Windows release not found. Run: flutter build windows --release" -ForegroundColor Yellow
}

# --------------- Step 1: Web build ---------------
if (-not $SkipWebBuild) {
  Write-Host "`n[2/4] Building Flutter web..." -ForegroundColor Cyan
  flutter build web --release
  if ($LASTEXITCODE -ne 0) { throw "flutter build web failed" }
} else {
  Write-Host "`n[2/4] Skipping web build (-SkipWebBuild)" -ForegroundColor Yellow
}

# --------------- Step 2: Copy download assets ---------------
Write-Host "`n[3/4] Copying download assets to build\web..." -ForegroundColor Cyan

# Copy the download page
$downloadHtml = "$RootDir\web_extras\download.html"
if (Test-Path $downloadHtml) {
  Copy-Item $downloadHtml "$RootDir\build\web\download.html" -Force
  Write-Host "  Copied download.html"
}

# Prefer installer .exe over ZIP if it exists
if (Test-Path $InstallerPath) {
  Copy-Item $InstallerPath "$RootDir\build\web\ResQ_EOC_Setup_v$Version.exe" -Force
  Write-Host "  Copied installer: ResQ_EOC_Setup_v$Version.exe ($([math]::Round((Get-Item $InstallerPath).Length/1MB,1)) MB)"
} elseif (Test-Path $ZipPath) {
  Copy-Item $ZipPath "$RootDir\build\web\ResQ_EOC_v${Version}_Windows.zip" -Force
  Write-Host "  Copied ZIP: ResQ_EOC_v${Version}_Windows.zip ($([math]::Round((Get-Item $ZipPath).Length/1MB,1)) MB)"
} else {
  Write-Host "  WARNING: No installer or ZIP found. Run Inno Setup first." -ForegroundColor Yellow
}

# --------------- Step 3: Firebase Deploy ---------------
Write-Host "`n[4/4] Deploying to Firebase Hosting..." -ForegroundColor Cyan
firebase deploy --only hosting
if ($LASTEXITCODE -ne 0) { throw "firebase deploy failed" }

Write-Host "`n✓ Deploy complete!" -ForegroundColor Green
Write-Host "  Web app:       https://resq-db-41ff8.web.app/" -ForegroundColor White
Write-Host "  Download page: https://resq-db-41ff8.web.app/download" -ForegroundColor White
