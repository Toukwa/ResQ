
# Dark Mode Color Replacement Script for ResQ App
# This script applies ThemeService-based color replacements across all admin/superadmin tab files

$files = @(
    "lib\admin\tabs\admin_dashboard_tab.dart",
    "lib\admin\tabs\admin_incidents_tab.dart",
    "lib\admin\tabs\admin_logs_tab.dart",
    "lib\admin\tabs\admin_management_screen.dart",
    "lib\admin\tabs\admin_map_tab.dart",
    "lib\admin\tabs\admin_media_tab.dart",
    "lib\admin\tabs\admin_settings_tab.dart",
    "lib\admin\tabs\admin_vehicles_tab.dart",
    "lib\superadmin\tabs\incidents_screen.dart",
    "lib\superadmin\tabs\logs_screen.dart",
    "lib\superadmin\tabs\management_screen.dart",
    "lib\superadmin\tabs\map_screen.dart",
    "lib\superadmin\tabs\media_screen.dart",
    "lib\superadmin\tabs\settings_screen.dart",
    "lib\superadmin\tabs\super_admin_dashboard.dart"
)

foreach ($file in $files) {
    if (-not (Test-Path $file)) {
        Write-Host "SKIP: $file not found"
        continue
    }

    $content = Get-Content $file -Raw

    # Check if ThemeService is already imported
    $hasImport = $content -match "theme_service\.dart"

    # 1. Add ThemeService import if missing
    if (-not $hasImport) {
        # Figure out relative path depth
        if ($file -like "*\admin\tabs\*") {
            $importLine = "import '../../services/theme_service.dart';"
        } elseif ($file -like "*\superadmin\tabs\*") {
            $importLine = "import '../../services/theme_service.dart';"
        } else {
            $importLine = "import 'services/theme_service.dart';"
        }

        # Insert after the last import line
        $content = $content -replace "(import 'package:flutter/material\.dart';)", "`$1`n$importLine"
        Write-Host "Added import to: $file"
    }

    # 2. In every build() method, add ThemeService variables after the opening brace
    # Pattern: `Widget build(BuildContext context) {` → add ts vars
    $buildHeader = @"
    final _ts = ThemeService.instance;
    final Color _cardBg = _ts.cardBackground;
    final Color _pageBg = _ts.pageBackground;
    final Color _textPrimary = _ts.textPrimary;
    final Color _textSecondary = _ts.textSecondary;
    final Color _border = _ts.borderColor;
    final Color _inputBg = _ts.inputBackground;
    final Color _subtleBg = _ts.subtleBackground;
"@

    Set-Content $file -Value $content -NoNewline
    Write-Host "Processed: $file"
}

Write-Host "Done."
