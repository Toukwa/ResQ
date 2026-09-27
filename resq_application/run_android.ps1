# ResQ - Android Debug Launcher (M2101K6G)
# Auto sets up ADB reverse port forwarding then runs Flutter on Android
# Usage: .\run_android.ps1

$ADB = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$TARGET_MODEL = "M2101K6G"

Write-Host ""
Write-Host "=== ResQ Android Debug Launcher ===" -ForegroundColor Cyan
Write-Host "    Target device: $TARGET_MODEL" -ForegroundColor Cyan
Write-Host ""

# Check ADB exists
if (-not (Test-Path $ADB)) {
    Write-Host "[ERROR] adb.exe not found at: $ADB" -ForegroundColor Red
    exit 1
}

# Find device serial by model name
$rawDevices = & $ADB devices -l
$targetLine = $rawDevices | Select-String -Pattern $TARGET_MODEL

if (-not $targetLine) {
    Write-Host "[WARN] $TARGET_MODEL not found. Retrying in 5s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    $rawDevices = & $ADB devices -l
    $targetLine = $rawDevices | Select-String -Pattern $TARGET_MODEL
    if (-not $targetLine) {
        Write-Host "[ERROR] Device $TARGET_MODEL not found. Check USB connection & USB debugging." -ForegroundColor Red
        exit 1
    }
}

# Extract serial (first token on the line)
$serial = ($targetLine.Line -split '\s+')[0]
Write-Host "[OK] Found $TARGET_MODEL with serial: $serial" -ForegroundColor Green
Write-Host ""

# Set up ADB reverse for port 3000 (Node.js backend)
Write-Host "[*] Setting up ADB reverse: phone:3000 -> PC:3000 ..." -ForegroundColor Cyan
$result = & $ADB -s $serial reverse tcp:3000 tcp:3000 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Port 3000 forwarded successfully!" -ForegroundColor Green
} else {
    Write-Host "[WARN] ADB reverse failed: $result" -ForegroundColor Yellow
}

# Verify
$check = & $ADB -s $serial reverse --list
Write-Host "[*] Active reverse rules: $check" -ForegroundColor DarkGray
Write-Host ""

# Run Flutter targeting this device
Write-Host "[*] Starting Flutter on $TARGET_MODEL ($serial)..." -ForegroundColor Cyan
Write-Host ""

flutter run -d $serial
