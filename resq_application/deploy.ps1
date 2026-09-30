# =============================================================
# ResQ - Firebase Hosting Deploy Script
# Publishes the download page (hosting/index.html) to https://resq-db-41ff8.web.app
#
# App releases are NOT uploaded here. Publish them on GitHub Releases
# (https://github.com/Toukwa/ResQ/releases/new) with these exact file names:
#   ResQ_EOC_Windows.zip   (flutter build windows --release, zip the Release folder)
#   ResQ_EOC.apk           (flutter build apk --release)
# The download page always links to the latest release, so it needs no edits.
# =============================================================

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "`nDeploying download page to Firebase Hosting..." -ForegroundColor Cyan
firebase deploy --only hosting
if ($LASTEXITCODE -ne 0) { throw "firebase deploy failed" }

Write-Host "`nDeploy complete: https://resq-db-41ff8.web.app/" -ForegroundColor Green
